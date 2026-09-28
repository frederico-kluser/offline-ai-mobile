#!/usr/bin/env python3
"""Exporta o checkpoint OFICIAL do Laya typed-decisions para ONNX fp32 (head fundida).

Substitui o artefacto de terceiros `m1rhan/laya-typed-decisions-ONNX` (4-bit, pensado
para browsers) por um export do checkpoint oficial `convaiinnovations/laya-typed-decisions`
sem compressão — fp32, ~1,69 GB — para os devices (Android + iOS) da app.

Contrato ONNX (`tools/specs/laya-encoding.md` §1) — idêntico ao artefacto antigo:

  in  input_ids      int64  [1, seq_len]
  in  attention_mask int64  [1, seq_len]
  in  marker_pos     int64  [1, n_markers]
  in  marker_mask    bool   [1, n_markers]
  in  qtype          int64  [1]        0=choice, 1=score, 2=noul
  out logits         float32 [1, n_markers]
  out act_logits     float32 [1, 2]

Batch estático 1; `seq_len`/`n_markers` dinâmicos; opset 18; EP CPU em device
(o grafo fp32 não usa contrib-ops, ao contrário do MatMulNBits antigo).

Uso (a partir da raiz do projeto):

  tools/.venv-laya/bin/python tools/laya_export_fp32.py \
      --model convaiinnovations/laya-typed-decisions \
      --output tools/laya_artifact/onnx/model.onnx

O script exporta, valida (onnx.checker + paridade torch vs onnxruntime em fixtures
choice/noul/score EN+PT) e imprime a tabela de fixtures para a spec.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys

import numpy as np
import torch

INPUT_NAMES = ["input_ids", "attention_mask", "marker_pos", "marker_mask", "qtype"]
OUTPUT_NAMES = ["logits", "act_logits"]

# Fixtures de verificação (§9 da spec): state EN do dossiê + caso PT.
FIXTURE_STATE_EN = (
    "Customer: my invoice was charged twice and nobody answers the phone!"
)
FIXTURE_QUESTIONS_EN = {
    "department": {
        "type": "choice",
        "instructions": "Which department should handle this ticket?",
        "criteria": {
            "billing": "charges, payments, invoices",
            "technical": "bugs, errors, outages",
            "account": "login, password, profile",
        },
    },
    "urgency": {
        "type": "noul",
        "instructions": "Is this request urgent?",
        "criteria": {"false": "can wait days", "true": "needs same-day response"},
    },
    "frustration": {
        "type": "score",
        "instructions": "How frustrated is the customer?",
        "criteria": ["calm", "annoyed", "angry"],
    },
}
FIXTURE_STATE_PT = (
    "Cliente: faturaram-me duas vezes o mesmo mês e ninguém responde ao telefone!"
)
FIXTURE_QUESTIONS_PT = {
    "departamento": {
        "type": "choice",
        "instructions": "Que departamento deve tratar este pedido?",
        "criteria": {
            "faturacao": "cobranças, pagamentos, faturas",
            "tecnico": "erros, falhas, bugs",
            "conta": "login, password, perfil",
        },
    },
    "urgencia": {
        "type": "noul",
        "instructions": "Este pedido é urgente?",
        "criteria": {"false": "pode esperar dias", "true": "precisa de resposta hoje"},
    },
}


def sha256_of(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def export(agent, output_path: str, legacy: bool) -> None:
    from torch.export import Dim

    model = agent.model.eval()
    os.makedirs(os.path.dirname(os.path.abspath(output_path)) or ".", exist_ok=True)

    dummy = (
        torch.randint(0, 50368, (1, 16), dtype=torch.long),
        torch.ones((1, 16), dtype=torch.long),
        torch.tensor([[5, 9]], dtype=torch.long),
        torch.tensor([[True, True]], dtype=torch.bool),
        torch.tensor([0], dtype=torch.long),
    )

    seq_len = Dim("seq_len", min=4, max=8192)
    # min=2: o DecisionModel só tem o branch topk(2) para K>=2 (noul é sempre 2);
    # K=1 (choice degenerado) não é suportado pelo export dinâmico.
    num_markers = Dim("num_markers", min=2, max=256)
    dynamic_shapes = (
        {1: seq_len},
        {1: seq_len},
        {1: num_markers},
        {1: num_markers},
        {},
    )

    print(f"A exportar para {output_path} (opset 18, fp32, batch estático 1)…")
    kwargs = dict(
        export_params=True,
        input_names=INPUT_NAMES,
        output_names=OUTPUT_NAMES,
        opset_version=18,
        dynamic_shapes=dynamic_shapes,
        # Ficheiro único: 1,69 GB < limite de 2 GB do protobuf, e o download no
        # device é um só ficheiro (sem sidecar .data).
        external_data=False,
    )
    if legacy:
        # Caminho TorchScript (dynamo=False): dynamic_axes em vez de dynamic_shapes.
        kwargs.pop("dynamic_shapes")
        kwargs["dynamic_axes"] = {
            "input_ids": {1: "seq_len"},
            "attention_mask": {1: "seq_len"},
            "marker_pos": {1: "num_markers"},
            "marker_mask": {1: "num_markers"},
            "logits": {1: "num_markers"},
        }
        kwargs["do_constant_folding"] = True
    with torch.no_grad():
        torch.onnx.export(
            model,
            dummy,
            output_path,
            dynamo=not legacy,
            **kwargs,
        )
    _merge_external_data(output_path)
    size = os.path.getsize(output_path)
    print(f"OK: {output_path} ({size / 1e9:.2f} GB, {size} bytes)")
    print(f"sha256: {sha256_of(output_path)}")


def _merge_external_data(output_path: str) -> None:
    """Funde `model.onnx.data` no `.onnx` — ficheiro único para o device.

    O exporter dynamo do torch externaliza os pesos acima de 1,5 GB mesmo com
    `external_data=False` (`_LARGE_MODEL_THRESHOLD`). O modelo fp32 (1,69 GB) cabe
    no limite de 2 GB do protobuf, por isso remontamos tudo num único ficheiro.
    """
    import onnx

    data_path = output_path + ".data"
    if not os.path.exists(data_path):
        return
    print(f"a fundir {os.path.basename(data_path)} em ficheiro único…")
    model = onnx.load(output_path, load_external_data=True)
    onnx.save_model(model, output_path, save_as_external_data=False)
    os.remove(data_path)


def _collate(agent, state: str, question: dict, max_len: int, head_max_len: int):
    from laya.agent import Agent
    from laya.common import QTYPES, build_sequence

    ids, markers = build_sequence(
        agent.tok, state, Agent._to_internal(question),
        max_len=max_len, head_max_len=head_max_len,
    )
    n = len(ids)
    k = len(markers)
    feeds = {
        "input_ids": np.array([ids], dtype=np.int64),
        "attention_mask": np.ones((1, n), dtype=np.int64),
        "marker_pos": np.array([markers], dtype=np.int64),
        "marker_mask": np.ones((1, k), dtype=bool),
        "qtype": np.array([QTYPES[question["type"]]], dtype=np.int64),
    }
    return feeds, ids, markers


def validate(agent, output_path: str) -> None:
    import onnx
    import onnxruntime as ort
    from laya.common import QTYPES

    print("onnx.checker…")
    onnx.checker.check_model(onnx.load(output_path))

    cfg = agent.cfg
    max_len = int(cfg.get("max_len", 1024))
    head_max_len = int(cfg.get("head_max_len", 256))
    print(f"calibração: max_len={max_len} head_max_len={head_max_len}")

    sess = ort.InferenceSession(
        output_path, providers=["CPUExecutionProvider"]
    )
    got = [i.name for i in sess.get_inputs()]
    want = [o.name for o in sess.get_outputs()]
    assert got == INPUT_NAMES, f"inputs inesperados: {got}"
    assert want == OUTPUT_NAMES, f"outputs inesperados: {want}"

    cases = []
    for state, qs in (
        (FIXTURE_STATE_EN, FIXTURE_QUESTIONS_EN),
        (FIXTURE_STATE_PT, FIXTURE_QUESTIONS_PT),
    ):
        for qid, q in qs.items():
            cases.append((state, qid, q))

    print(f"paridade torch vs onnxruntime ({len(cases)} casos)…")
    worst = 0.0
    for state, qid, q in cases:
        feeds, ids, markers = _collate(agent, state, q, max_len, head_max_len)
        with torch.no_grad():
            t_logits, t_act = agent.model(
                torch.from_numpy(feeds["input_ids"]),
                torch.from_numpy(feeds["attention_mask"]),
                torch.from_numpy(feeds["marker_pos"]),
                torch.from_numpy(feeds["marker_mask"]),
                torch.from_numpy(feeds["qtype"]),
            )
        o_logits, o_act = sess.run(None, feeds)
        d1 = float(np.abs(t_logits.numpy() - o_logits).max())
        d2 = float(np.abs(t_act.numpy() - o_act).max())
        worst = max(worst, d1, d2)
        same = bool(
            (t_logits.numpy().argmax(-1) == o_logits.argmax(-1)).all()
        )
        print(
            f"  {qid} ({q['type']}): K={len(markers)} L={len(ids)} "
            f"max|Δlogits|={d1:.2e} max|Δact|={d2:.2e} argmax={'igual' if same else 'DIFERE'}"
        )
        assert same, f"argmax divergente em {qid}"
    print(f"paridade OK (pior desvio absoluto {worst:.2e})")

    # Tabela de fixtures para tools/specs/laya-encoding.md §9 (decode de referência).
    print("\n--- fixtures (decode de referência Agent.system_one) ---")
    for state, qs in (
        (FIXTURE_STATE_EN, FIXTURE_QUESTIONS_EN),
        (FIXTURE_STATE_PT, FIXTURE_QUESTIONS_PT),
    ):
        out = agent.system_one(state, qs)
        for qid, ans in out["answers"].items():
            print(json.dumps({"state": state[:24] + "…", "q": qid, **ans},
                             ensure_ascii=False))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--model", default="convaiinnovations/laya-typed-decisions")
    ap.add_argument("--output", required=True)
    ap.add_argument("--legacy", action="store_true",
                    help="exportador TorchScript (dynamo=False)")
    ap.add_argument("--skip-validate", action="store_true")
    args = ap.parse_args()

    from laya.agent import Agent

    print(f"A carregar Agent({args.model!r})…")
    agent = Agent(args.model, compile=False, device="cpu")
    print(f"cfg: model_name={agent.cfg.get('model_name')} "
          f"temperature={agent.cfg.get('temperature')}")

    export(agent, args.output, legacy=args.legacy)
    if not args.skip_validate:
        validate(agent, args.output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
