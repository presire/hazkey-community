#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
@file build_symbol_dictionary.py
@brief 補助記号辞書 (SymbolDictionary/symbol_dictionary.tsv) を生成する

手作りの優先表とMozcのdata/symbol/symbol.tsvを読み、「読み<TAB>記号<TAB>tier」のTSVを同じ入力からは常に同じ内容で生成する
優先表は読みごとの並び順とtierを与え、Mozcは収録する記号を補う

入力: SymbolDictionary/symbol_priority.tsv (読み・記号・tierの3列)
入力: Mozcのdata/symbol/symbol.tsv (google/mozc@a4541dfで固定)
出力: SymbolDictionary/symbol_dictionary.tsv (UTF-8、末尾改行あり、1MiB以下)

読みはひらがな (U+3041〜U+3096) と長音符 (U+30FC) だけからなる2文字以上に限る
Mozcの読み列は空白区切りの複数読みなので読みごとに展開して、優先表にtierがある読みはそのtier、無い読みはBとする

記号かどうかの判定はサーバの読込時に行うため、このスクリプトでは行わない
並び順はMozcのordering_rule / sorting_tableによる出力順の再現ではない

Mozcのsymbol.tsvは再配布を避けるため同梱せず、呼び出し側が用意する

使い方: python3 scripts/build_symbol_dictionary.py <Mozcのsymbol.tsv> [--priority PATH] [--output PATH]
終了コード: 0 = 生成成功、1 = 入力不正または書込失敗
"""

from __future__ import annotations

import argparse
import hashlib
import re
import sys
from collections.abc import Iterable, Sequence
from pathlib import Path
from typing import Final

# 固定したMozcのsymbol.tsvのSHA-256
# symbol.tsvはBSD-3-Clauseで、帰属はThirdPartyLicenses/Mozc-LICENSE.txtに記録している
# 上流で記号が増減しても生成物が黙って変わらないよう、生成時に照合する
MOZC_SYMBOL_TSV_SHA256: Final = (
    "bc68b032a195f203dccba6f95667424199ba9b185fee2be64eeaa959253c097a"
)

# 生成物の上限 (サーバの読込上限と同じ1MiB)
MAX_OUTPUT_BYTES: Final = 1024 * 1024
# 許可する読み (ひらがなと長音符だけで2文字以上)
READING_PATTERN: Final = re.compile(r"[\u3041-\u3096\u30fc]{2,}")
VALID_TIERS: Final = ("A", "B")  # tierとして許可する値
DEFAULT_TIER: Final = "B"        # 優先表にtierが無い読みの扱い

SCRIPT_DIR: Final = Path(__file__).resolve().parent  # このスクリプトの場所
# 既定の優先表 (SymbolDictionary/symbol_priority.tsv)
DEFAULT_PRIORITY_PATH: Final = SCRIPT_DIR.parent / "SymbolDictionary" / "symbol_priority.tsv"
# 既定の出力先 (SymbolDictionary/symbol_dictionary.tsv)
DEFAULT_OUTPUT_PATH: Final = SCRIPT_DIR.parent / "SymbolDictionary" / "symbol_dictionary.tsv"


class SymbolDictionaryBuildError(Exception):
    """
    @brief 入力データが不正で生成を継続できないことを表す

    呼び出し側はこの例外を捕捉し、出力を書かずに終了コード1で終わる
    """


def is_valid_reading(reading: str) -> bool:
    """
    @brief 読みが許可した文字集合だけからなる2文字以上の文字列かを返す

    Args:
        reading: 判定する読み

    Returns:
        ひらがなと長音符だけで2文字以上ならTrue、それ以外はFalse

    Note:
        1文字の読みは変換の対象として短すぎるため除外する
        カタカナ・漢字・ASCII・記号を含む読みは、利用者が入力できないため除外する
    """
    return READING_PATTERN.fullmatch(reading) is not None


def parse_priority(text: str) -> list[tuple[str, str, str]]:
    """
    @brief 優先表を「読み・記号・tier」の組の並びへ変換する

    Args:
        text: 優先表 (「読み<TAB>記号<TAB>tier」を改行で並べたもの) の全文

    Returns:
        入力順の「読み・記号・tier」の組の並び

    Raises:
        SymbolDictionaryBuildError: 列数・tier・読みが不正な場合、記号が空の場合、または、同じ読みでtierが食い違う場合

    Note:
        優先表は手作りデータなので、誤りを黙って読み飛ばさず全てエラーにする
        生成物が意図と違う並びのまま配備されるのを防ぐため
    """
    rows: list[tuple[str, str, str]] = []
    tiers: dict[str, str] = {}
    for line_number, line in enumerate(text.splitlines(), start=1):
        if not line:
            continue
        columns = line.split("\t")
        if len(columns) != 3:
            raise SymbolDictionaryBuildError(
                f"priority line {line_number}: expected 3 columns, got {len(columns)}"
            )
        reading, symbol, tier = columns
        if not is_valid_reading(reading):
            raise SymbolDictionaryBuildError(
                f"priority line {line_number}: invalid reading {reading!r}"
            )
        if not symbol:
            raise SymbolDictionaryBuildError(f"priority line {line_number}: empty symbol")
        if tier not in VALID_TIERS:
            raise SymbolDictionaryBuildError(
                f"priority line {line_number}: invalid tier {tier!r}"
            )
        previous = tiers.setdefault(reading, tier)
        if previous != tier:
            raise SymbolDictionaryBuildError(
                f"priority line {line_number}: tier {tier} conflicts with {previous} for {reading}"
            )
        rows.append((reading, symbol, tier))
    return rows


def parse_mozc_symbols(text: str) -> list[tuple[str, str]]:
    """
    @brief Mozcのsymbol.tsvを入力行順の「読み・記号」の組へ展開する

    Args:
        text: Mozcのdata/symbol/symbol.tsvの全文

    Returns:
        入力行順の「読み・記号」の組の並び

    Note:
        見出し行 (POSで始まる行)・コメント行・空行・3列未満の行は読み飛ばす
        Mozc側の書式が多少変わっても生成が止まらないようにするため、読み列は空白区切りの複数読みなので読みごとに展開する
        記号が空の行は候補にならないため除外する
    """
    pairs: list[tuple[str, str]] = []
    for line in text.splitlines():
        if not line or line.startswith("#") or line.startswith("POS\t"):
            continue
        columns = line.split("\t")
        if len(columns) < 3:
            continue
        symbol = columns[1]
        if not symbol:
            continue
        for reading in columns[2].split(" "):
            if is_valid_reading(reading):
                pairs.append((reading, symbol))
    return pairs


def build_entries(
    priority: Sequence[tuple[str, str, str]],
    mozc_pairs: Iterable[tuple[str, str]],
) -> list[tuple[str, str, str]]:
    """
    @brief 優先表とMozcの組を合わせ、読みの符号点順に並べた辞書の行を返す

    Args:
        priority: 優先表の「読み・記号・tier」の組の並び
        mozc_pairs: Mozcの「読み・記号」の組の並び (入力行順)

    Returns:
        読みの符号点順の「読み・記号・tier」の組の並び

    Note:
        同じ読みの中は優先表の順、次にMozcの入力行順とする
        同じ読み・記号の組は最初の1件だけを残して、表記の重複を候補に出さない
        tierは読み単位の属性なので、優先表に無い読みはDEFAULT_TIERを使用する
    """
    tiers = {reading: tier for reading, _, tier in priority}
    symbols_by_reading: dict[str, list[str]] = {}
    seen: set[tuple[str, str]] = set()

    def add(reading: str, symbol: str) -> None:
        """まだ無い「読み・記号」の組だけを、その読みの並びの末尾へ加える"""
        if (reading, symbol) in seen:
            return
        seen.add((reading, symbol))
        symbols_by_reading.setdefault(reading, []).append(symbol)

    for reading, symbol, _ in priority:
        add(reading, symbol)
    for reading, symbol in mozc_pairs:
        add(reading, symbol)

    return [
        (reading, symbol, tiers.get(reading, DEFAULT_TIER))
        for reading in sorted(symbols_by_reading)
        for symbol in symbols_by_reading[reading]
    ]


def render(entries: Iterable[tuple[str, str, str]]) -> bytes:
    """
    @brief 辞書の行をTSVのバイト列にし、上限を超えればエラーにする

    Args:
        entries: 「読み・記号・tier」の組の並び

    Returns:
        末尾改行付きのUTF-8のバイト列

    Raises:
        SymbolDictionaryBuildError: 変換後のバイト数がMAX_OUTPUT_BYTESを超える場合

    Note:
        上限はサーバが読める辞書の上限と同じ値にしてある
        配備後に読めない辞書を生成しないため、書き出す前にここで止める
    """
    data = "".join(f"{reading}\t{symbol}\t{tier}\n" for reading, symbol, tier in entries)
    encoded = data.encode("utf-8")
    if len(encoded) > MAX_OUTPUT_BYTES:
        raise SymbolDictionaryBuildError(
            f"output is {len(encoded)} bytes, exceeds {MAX_OUTPUT_BYTES}"
        )
    return encoded


def build(mozc_path: Path, priority_path: Path, *, verify_hash: bool = True) -> bytes:
    """
    @brief 入力ファイルから辞書のTSVを生成して返す

    Args:
        mozc_path: Mozcのdata/symbol/symbol.tsvのパス
        priority_path: 優先表のパス
        verify_hash: TrueならMozcのsymbol.tsvのSHA-256を固定値と照合する

    Returns:
        生成したTSVのバイト列

    Raises:
        OSError: 入力ファイルを読めない場合
        UnicodeDecodeError: 入力ファイルがUTF-8として読めない場合
        SymbolDictionaryBuildError: 固定値とSHA-256が一致しない場合、または入力が不正な場合

    Note:
        ハッシュの照合は、上流のMozcで記号が増減した時に生成物が黙って変わり、配備済みの辞書と食い違うのを防ぐために行う
    """
    mozc_bytes = mozc_path.read_bytes()
    if verify_hash:
        digest = hashlib.sha256(mozc_bytes).hexdigest()
        if digest != MOZC_SYMBOL_TSV_SHA256:
            raise SymbolDictionaryBuildError(
                f"{mozc_path}: SHA-256 {digest} does not match pinned {MOZC_SYMBOL_TSV_SHA256}"
            )
    priority = parse_priority(priority_path.read_text(encoding="utf-8"))
    mozc_pairs = parse_mozc_symbols(mozc_bytes.decode("utf-8"))
    return render(build_entries(priority, mozc_pairs))


def main(argv: Sequence[str] | None = None) -> int:
    """
    @brief コマンドライン引数から辞書を生成し、出力先へ書く

    Args:
        argv: コマンドライン引数 (Noneならsys.argvを使う)

    Returns:
        終了コード (0 = 生成成功、1 = 入力不正または書込失敗)

    Note:
        生成に失敗した場合は出力を書かない
        中途半端な辞書が残り、サーバがそれを読むのを防ぐため
    """
    parser = argparse.ArgumentParser(description="補助記号辞書を生成する")
    parser.add_argument("mozc_symbol_tsv", type=Path, help="Mozc の data/symbol/symbol.tsv")
    parser.add_argument("--priority", type=Path, default=DEFAULT_PRIORITY_PATH)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT_PATH)
    args = parser.parse_args(argv)
    try:
        output = build(args.mozc_symbol_tsv, args.priority)
    except (OSError, UnicodeDecodeError, SymbolDictionaryBuildError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    args.output.write_bytes(output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
