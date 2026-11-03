#!/usr/bin/env python3
"""Shell-free bridge used by the Nau TTS Mac application."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description="Generate speech for Nau TTS Mac")
    result.add_argument("--check", action="store_true", help="validate the local MLX install")
    result.add_argument("--list-voices", action="store_true", help="list built-in voices")
    result.add_argument("--text")
    result.add_argument("--voice", default="Bruno")
    result.add_argument("--reference", type=Path)
    result.add_argument("--reference-text")
    result.add_argument("--output", type=Path)
    result.add_argument("--preset", choices=("stable", "expressive"), default="stable")
    return result


def emit(payload: dict[str, object]) -> None:
    print(json.dumps(payload, ensure_ascii=False), flush=True)


def main() -> int:
    args = parser().parse_args()

    try:
        import mlx.core as mx
        from kittenml import KittenTTS as NauTTS

        if args.check:
            emit({"ok": True, "device": str(mx.default_device()), "backend": "mlx"})
            return 0

        if args.list_voices:
            model = NauTTS("KittenML/kitten-tts-2", backend="mlx")
            emit({"ok": True, "voices": sorted(model.available_voices)})
            return 0

        if not args.text or not args.text.strip():
            raise ValueError("Nội dung không được để trống.")
        if args.output is None:
            raise ValueError("Chưa chọn file đầu ra.")

        output = args.output.expanduser().resolve()
        if output.suffix.lower() != ".wav":
            raise ValueError("File đầu ra phải có đuôi .wav.")
        output.parent.mkdir(parents=True, exist_ok=True)

        speaker: dict[str, str] = {}
        if args.reference is not None:
            reference = args.reference.expanduser().resolve()
            if not reference.is_file():
                raise ValueError("Không tìm thấy file giọng tham chiếu.")
            speaker["reference"] = str(reference)
            if args.reference_text and args.reference_text.strip():
                speaker["reference_text"] = args.reference_text.strip()
        else:
            speaker["voice"] = args.voice.strip() or "Bruno"

        model = NauTTS("KittenML/kitten-tts-2", backend="mlx")
        model.generate_to_file(
            args.text.strip(),
            str(output),
            preset=args.preset,
            **speaker,
        )
        emit({"ok": True, "output": str(output), "backend": "mlx"})
        return 0
    except Exception as error:
        emit({"ok": False, "error": str(error)})
        return 1


if __name__ == "__main__":
    sys.exit(main())
