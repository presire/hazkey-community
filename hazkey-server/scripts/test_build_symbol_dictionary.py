#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
@file test_build_symbol_dictionary.py
@brief build_symbol_dictionary.pyの記号辞書生成のテスト

固定した優先表とMozcのsymbol.tsvから辞書を生成して、読みの採否・並び順・tierの継承・重複排除・上限の扱いを検証する
コミット済みの辞書が生成規則を満たすことも常に検査する
Mozcの実データが無い環境では、実データを使う検査だけを飛ばす

使い方: python3 -m unittest discover -s hazkey-server/scripts -p 'test_*.py' -v
"""

from __future__ import annotations

import contextlib
import io
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))  # scripts/ をそのままimportするため

import build_symbol_dictionary as builder

SCRIPT_DIR = Path(__file__).resolve().parent                        # このテストの場所
SYMBOL_DIR = SCRIPT_DIR.parent / "SymbolDictionary"                 # 辞書と優先表の置き場
PRIORITY_PATH = SYMBOL_DIR / "symbol_priority.tsv"                  # 手作りの優先表
COMMITTED_DICTIONARY_PATH = SYMBOL_DIR / "symbol_dictionary.tsv"    # コミット済みの辞書

# 固定したMozcのsymbol.tsv (無ければ実データの検査だけを飛ばす)
DEFAULT_MOZC_PATH = Path("/tmp/opencode/symconv/symbol.tsv")

# 辞書に必ず含まれる読み (主要な記号名を取りこぼしていないことの確認用)
REQUIRED_READINGS = (
    "きごう",
    "さんてん",
    "かぎかっこ",
    "にじゅうかっこ",
    "りーだー",
    "たす",
    "やじるし",
)


def mozc_text(*rows: str) -> str:
    """
    @brief Mozcのsymbol.tsvと同じ列構成の本文を作る

    Args:
        rows: タブ区切りの1行分の文字列 (可変長)

    Returns:
        各行に改行を付けて連結した本文
    """
    return "".join(f"{row}\n" for row in rows)


def write_priority(directory: Path, text: str) -> Path:
    """
    @brief 一時ディレクトリに優先表を書く

    Args:
        directory: 書き込み先のディレクトリ
        text: 優先表の内容

    Returns:
        書いた優先表のパス
    """
    path = directory / "symbol_priority.tsv"
    path.write_text(text, encoding="utf-8")
    return path


def write_mozc(directory: Path, text: str) -> Path:
    """
    @brief 一時ディレクトリにMozcのsymbol.tsvを書く

    Args:
        directory: 書き込み先のディレクトリ
        text: symbol.tsvの内容

    Returns:
        書いたsymbol.tsvのパス
    """
    path = directory / "symbol.tsv"
    path.write_text(text, encoding="utf-8")
    return path


def real_mozc_path() -> Path:
    """
    @brief 実データの検査に使うMozcのsymbol.tsvのパスを返す

    Returns:
        symbol.tsvのパス

    Note:
        環境変数HAZKEY_MOZC_SYMBOL_TSVで差し替えられる
        リポジトリに同梱しない入力なので、無い環境では検査を飛ばす
    """
    return Path(os.environ.get("HAZKEY_MOZC_SYMBOL_TSV", str(DEFAULT_MOZC_PATH)))


class ReadingValidationTests(unittest.TestCase):
    """
    @brief 読みの文字集合と長さの判定を固定する
    """

    def test_hiragana_and_long_vowel_are_valid(self) -> None:
        for reading in ("やじるし", "りーだー", "かっこいい", "から", "あー"):
            with self.subTest(reading=reading):
                self.assertTrue(builder.is_valid_reading(reading))

    def test_single_character_is_invalid(self) -> None:
        for reading in ("ほ", "ー", "や", ""):
            with self.subTest(reading=reading):
                self.assertFalse(builder.is_valid_reading(reading))

    def test_katakana_kanji_ascii_and_symbol_are_invalid(self) -> None:
        for reading in ("ヤジルシ", "矢印", "arrow", "やじるし!", "やじ るし", "→"):
            with self.subTest(reading=reading):
                self.assertFalse(builder.is_valid_reading(reading))

    def test_long_vowel_is_u30fc(self) -> None:
        # 読みの許可文字にU+30FCを入れているため、カタカナの「ー」が同じ符号点であることを固定する
        self.assertEqual("りーだー"[1], "\u30fc")


class MozcParsingTests(unittest.TestCase):
    """
    @brief Mozcのsymbol.tsvの読み飛ばし・読みの展開・除外を固定する
    """

    def test_expands_space_separated_readings(self) -> None:
        pairs = builder.parse_mozc_symbols(
            mozc_text("記号\t→\tやじるし みぎ ゆびさし")
        )
        self.assertEqual(
            pairs,
            [("やじるし", "→"), ("みぎ", "→"), ("ゆびさし", "→")],
        )

    def test_keeps_long_vowel_in_reading(self) -> None:
        pairs = builder.parse_mozc_symbols(
            mozc_text("句読点\t…\tさんてんりーだー りーだー")
        )
        self.assertEqual(
            pairs,
            [("さんてんりーだー", "…"), ("りーだー", "…")],
        )
        self.assertEqual(pairs[1][0], "りーだー")

    def test_skips_header_comment_blank_short_and_empty_symbol(self) -> None:
        text = mozc_text(
            "POS\tCHAR\tReading (space separated)",
            "# コメント行",
            "",
            "記号\t\tから",
            "記号\t×",
            "記号\t○\tまる\t説明",
        )
        self.assertEqual(builder.parse_mozc_symbols(text), [("まる", "○")])

    def test_skips_invalid_readings(self) -> None:
        text = mozc_text("記号\t↑\tうえ ヤジルシ 矢印 arrow → ほ")
        self.assertEqual(builder.parse_mozc_symbols(text), [("うえ", "↑")])

    def test_preserves_input_order(self) -> None:
        text = mozc_text(
            "記号\t■\tしかく",
            "記号\t□\tしかく",
            "記号\t○\tまる",
        )
        self.assertEqual(
            builder.parse_mozc_symbols(text),
            [("しかく", "■"), ("しかく", "□"), ("まる", "○")],
        )


class PriorityParsingTests(unittest.TestCase):
    """
    @brief 手作りの優先表の解釈と不正の拒否を固定する
    """

    def test_parses_rows_and_skips_blank_lines(self) -> None:
        text = "やじるし\t→\tA\nやじるし\t←\tA\n\nきごう\t※\tB\n"
        self.assertEqual(
            builder.parse_priority(text),
            [("やじるし", "→", "A"), ("やじるし", "←", "A"), ("きごう", "※", "B")],
        )

    def test_rejects_wrong_column_count(self) -> None:
        for text in ("やじるし\t→\n", "やじるし\t→\tA\textra\n"):
            with self.subTest(text=text):
                with self.assertRaises(builder.SymbolDictionaryBuildError):
                    builder.parse_priority(text)

    def test_rejects_invalid_tier(self) -> None:
        with self.assertRaises(builder.SymbolDictionaryBuildError):
            builder.parse_priority("やじるし\t→\tC\n")

    def test_rejects_invalid_reading(self) -> None:
        for reading in ("ヤジルシ", "矢印", "ほ"):
            with self.subTest(reading=reading):
                with self.assertRaises(builder.SymbolDictionaryBuildError):
                    builder.parse_priority(f"{reading}\t→\tA\n")

    def test_rejects_empty_symbol(self) -> None:
        with self.assertRaises(builder.SymbolDictionaryBuildError):
            builder.parse_priority("やじるし\t\tA\n")

    def test_rejects_conflicting_tier_for_same_reading(self) -> None:
        with self.assertRaises(builder.SymbolDictionaryBuildError):
            builder.parse_priority("やじるし\t→\tA\nやじるし\t←\tB\n")


class EntryBuildingTests(unittest.TestCase):
    """
    @brief 優先表とMozcの統合・tierの継承・重複排除・並び順を固定する
    """

    def test_priority_symbols_come_before_mozc_symbols(self) -> None:
        priority = [("うえ", "↑", "A"), ("あい", "あ", "A")]
        mozc = [("あい", "い"), ("うえ", "上"), ("あい", "あ")]
        self.assertEqual(
            builder.build_entries(priority, mozc),
            [
                ("あい", "あ", "A"),
                ("あい", "い", "A"),
                ("うえ", "↑", "A"),
                ("うえ", "上", "A"),
            ],
        )

    def test_readings_are_sorted_by_code_point(self) -> None:
        rows = builder.build_entries(
            [("りーだー", "…", "A")],
            [("あい", "あ"), ("たす", "＋")],
        )
        self.assertEqual([reading for reading, _, _ in rows], ["あい", "たす", "りーだー"])

    def test_duplicate_reading_symbol_pair_is_kept_once(self) -> None:
        rows = builder.build_entries([("あい", "○", "A")], [("あい", "○"), ("あい", "●")])
        self.assertEqual(rows, [("あい", "○", "A"), ("あい", "●", "A")])

    def test_priority_tier_is_inherited_and_mozc_defaults_to_b(self) -> None:
        rows = builder.build_entries(
            [("りーだー", "…", "A"), ("ほし", "☆", "B")],
            [("りーだー", "‥"), ("たす", "＋")],
        )
        tiers = {reading: tier for reading, _, tier in rows}
        self.assertEqual(tiers["りーだー"], "A")
        self.assertEqual(tiers["ほし"], "B")
        self.assertEqual(tiers["たす"], "B")

    def test_priority_order_is_kept_per_reading(self) -> None:
        rows = builder.build_entries(
            [("やじるし", "↓", "A"), ("やじるし", "→", "A")],
            [("やじるし", "↑")],
        )
        self.assertEqual([symbol for _, symbol, _ in rows], ["↓", "→", "↑"])


class RenderTests(unittest.TestCase):
    """
    @brief TSVの書式と上限を固定する
    """

    def test_renders_tab_separated_rows_with_trailing_newline(self) -> None:
        self.assertEqual(
            builder.render([("あい", "○", "A"), ("たす", "＋", "B")]),
            "あい\t○\tA\nたす\t＋\tB\n".encode("utf-8"),
        )

    def test_rejects_output_larger_than_limit(self) -> None:
        entries = (("あい", f"{index}", "B") for index in range(120_000))
        with self.assertRaises(builder.SymbolDictionaryBuildError):
            builder.render(entries)

    def test_accepts_output_at_the_limit(self) -> None:
        # サーバの読込上限と同じ1MiBちょうどは許可し、1バイトでも超えたら拒否する
        entry = ("ああ", "abcdef", "A")
        row = builder.render([entry])
        self.assertEqual(len(row), 16)
        count = builder.MAX_OUTPUT_BYTES // len(row)
        data = builder.render([entry] * count)
        self.assertEqual(len(data), builder.MAX_OUTPUT_BYTES)
        with self.assertRaises(builder.SymbolDictionaryBuildError):
            builder.render([entry] * (count + 1))


class BuildTests(unittest.TestCase):
    """
    @brief 入力ファイルからの生成と失敗時の扱いを固定する
    """

    def test_same_input_produces_identical_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            mozc = write_mozc(root, mozc_text("記号\t→\tやじるし みぎ", "記号\t↑\tうえ"))
            priority = write_priority(root, "やじるし\t⇔\tA\n")
            first = builder.build(mozc, priority, verify_hash=False)
            second = builder.build(mozc, priority, verify_hash=False)
            self.assertEqual(first, second)
            self.assertEqual(
                first.decode("utf-8"),
                "うえ\t↑\tB\nみぎ\t→\tB\nやじるし\t⇔\tA\nやじるし\t→\tA\n",
            )

    def test_hash_mismatch_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            mozc = write_mozc(root, mozc_text("記号\t→\tやじるし"))
            priority = write_priority(root, "やじるし\t⇔\tA\n")
            with self.assertRaises(builder.SymbolDictionaryBuildError):
                builder.build(mozc, priority)
            # テスト用の入力は固定値と一致しないため、照合を外した経路で生成内容を確認する
            self.assertEqual(
                builder.build(mozc, priority, verify_hash=False),
                "やじるし\t⇔\tA\nやじるし\t→\tA\n".encode("utf-8"),
            )

    def test_main_reports_error_without_writing_output(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            mozc = write_mozc(root, mozc_text("記号\t→\tやじるし"))
            priority = write_priority(root, "やじるし\t⇔\tA\n")
            output = root / "symbol_dictionary.tsv"
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                status = builder.main(
                    [str(mozc), "--priority", str(priority), "--output", str(output)]
                )
            self.assertEqual(status, 1)
            self.assertFalse(output.exists())
            self.assertIn("SHA-256", stderr.getvalue())


class CommittedDictionaryTests(unittest.TestCase):
    """
    @brief コミット済みの辞書が生成規則と上限を満たすことを常に検査する
    """

    @classmethod
    def setUpClass(cls) -> None:
        cls.data = COMMITTED_DICTIONARY_PATH.read_bytes()
        cls.text = cls.data.decode("utf-8")

    def test_output_is_at_most_one_mib_with_trailing_newline(self) -> None:
        self.assertLessEqual(len(self.data), builder.MAX_OUTPUT_BYTES)
        self.assertTrue(self.data.endswith(b"\n"))

    def test_every_row_has_three_columns_and_valid_values(self) -> None:
        rows = self.text.splitlines()
        self.assertTrue(rows)
        for line_number, line in enumerate(rows, start=1):
            columns = line.split("\t")
            with self.subTest(line=line_number):
                self.assertEqual(len(columns), 3)
                reading, symbol, tier = columns
                self.assertTrue(builder.is_valid_reading(reading))
                self.assertTrue(symbol)
                self.assertIn(tier, builder.VALID_TIERS)

    def test_readings_are_contiguous_and_keep_one_tier(self) -> None:
        tier_by_reading: dict[str, str] = {}
        finished: set[str] = set()
        previous = None
        for line in self.text.splitlines():
            reading, _, tier = line.split("\t")
            if reading != previous:
                if previous is not None:
                    finished.add(previous)
                self.assertNotIn(reading, finished, reading)
                previous = reading
            self.assertEqual(tier_by_reading.setdefault(reading, tier), tier)
        self.assertIsNotNone(previous)

    def test_contains_the_required_readings(self) -> None:
        readings = {line.split("\t")[0] for line in self.text.splitlines()}
        for reading in REQUIRED_READINGS:
            with self.subTest(reading=reading):
                self.assertIn(reading, readings)

    def test_priority_rows_are_present_in_the_dictionary(self) -> None:
        symbols_by_reading: dict[str, set[str]] = {}
        for line in self.text.splitlines():
            reading, symbol, _ = line.split("\t")
            symbols_by_reading.setdefault(reading, set()).add(symbol)
        for reading, symbol, _ in builder.parse_priority(
            PRIORITY_PATH.read_text(encoding="utf-8")
        ):
            with self.subTest(reading=reading, symbol=symbol):
                self.assertIn(symbol, symbols_by_reading.get(reading, set()))


class PinnedMozcDataTests(unittest.TestCase):
    """
    @brief 固定したMozcのsymbol.tsvがある環境だけで実データの再生成を検査する
    """

    def setUp(self) -> None:
        self.mozc = real_mozc_path()
        if not self.mozc.is_file():
            self.skipTest(f"Mozc symbol.tsv not found: {self.mozc}")

    def test_build_matches_the_committed_dictionary(self) -> None:
        self.assertEqual(
            builder.build(self.mozc, PRIORITY_PATH),
            COMMITTED_DICTIONARY_PATH.read_bytes(),
        )

    def test_main_writes_the_committed_dictionary(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "symbol_dictionary.tsv"
            status = builder.main(
                [
                    str(self.mozc),
                    "--priority",
                    str(PRIORITY_PATH),
                    "--output",
                    str(output),
                ]
            )
            self.assertEqual(status, 0)
            self.assertEqual(output.read_bytes(), COMMITTED_DICTIONARY_PATH.read_bytes())


if __name__ == "__main__":
    unittest.main()
