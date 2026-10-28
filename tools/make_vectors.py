"""Genera i vettori di prova condivisi tra app Mac (Swift) e pagina telefono (JS).

Formato di un frame: [id messaggio u8][indice u16 BE][totale u16 BE][dati].
Scritto in modo indipendente dalle due implementazioni, così i test non sono circolari.
"""
import json
import pathlib

HEADER = 5


def frames(payload: bytes, message_id: int, max_frame: int) -> list[str]:
    chunk = max(1, max_frame - HEADER)
    count = max(1, -(-len(payload) // chunk))
    out = []
    for i in range(count):
        part = payload[i * chunk:(i + 1) * chunk]
        head = bytes([message_id]) + i.to_bytes(2, "big") + count.to_bytes(2, "big")
        out.append((head + part).hex())
    return out


CASES = [
    ("vuoto", "", 7, 20),
    ("corto", "ciao", 1, 20),
    ("tre frame", "0123456789" * 4, 255, 20),
    ("utf8 spezzato", "Nota àèìòù — fine", 42, 8),
    ("json grande", json.dumps({"t": "state", "slide": 3, "count": 12}), 9, 23),
]

vectors = [
    {
        "name": name,
        "messageId": mid,
        "maxFrameSize": max_frame,
        "payload": text,
        "frames": frames(text.encode("utf-8"), mid, max_frame),
    }
    for name, text, mid, max_frame in CASES
]

target = pathlib.Path(__file__).resolve().parent.parent / "shared" / "framing-vectors.json"
target.write_text(json.dumps(vectors, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(f"scritti {len(vectors)} vettori in {target}")
