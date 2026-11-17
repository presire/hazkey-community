#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
@file test_symbol_corpus.py
@brief 記号変換の評価コーパス (Fixtures/symbol-corpus.json) のスキーマと内容のテスト

コーパスは、読みと文脈の組ごとに期待する記号と普通の正解候補を持ち、tuning (調整用) とholdout (最終評価用) に分かれている
同じ読みが両方のsplitに現れると評価の独立性が崩れるため、splitの重複も検査する
tierと記号の表記は、コミット済みの補助記号辞書と一致していることを検査する

使い方: python3 -m unittest discover -s hazkey-server/scripts -p 'test_*.py' -v
"""

from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent  # このテストの場所
SERVER_DIR = SCRIPT_DIR.parent                # hazkey-serverのルート
# 評価コーパス (読み・文脈・期待記号・tier・splitを持つ)
CORPUS_PATH = SERVER_DIR / "Tests" / "hazkey-server" / "Fixtures" / "symbol-corpus.json"
# コミット済みの補助記号辞書 (tierと表記の整合を検査する)
DICTIONARY_PATH = SERVER_DIR / "SymbolDictionary" / "symbol_dictionary.tsv"

# 許可する読み (ひらがなと長音符だけで2文字以上)
READING_PATTERN = re.compile(r"\A[\u3041-\u3096\u30fc]{2,}\Z")
# ケースID (小文字と数字のハイフン区切り)
ID_PATTERN = re.compile(r"\A[a-z0-9]+(?:-[a-z0-9]+)*\Z")
TIERS = ("A", "B")              # tierとして許可する値
SPLITS = ("tuning", "holdout")  # 評価データの分割
# 分母から外す理由 (1文字読み・直接入力)
EXCLUDED_REASONS = ("single-character-reading", "direct-input")

# 各ケースに必須のキー (欠落と未知のキーの両方を検出する)
REQUIRED_CASE_KEYS = {
    "id",
    "reading",
    "context",
    "tier",
    "split",
    "expectedSymbols",
    "expectedWords",
    "partialReadingConflict",
}
OPTIONAL_CASE_KEYS = {"notes"}                    # 各ケースで省略できるキー
REQUIRED_EXCLUDED_KEYS = {"reading", "reason", "notes"}  # 分母から外す読みの必須キー

REQUIRED_READINGS = ("した", "から")              # 曖昧な読みの代表 (Bティアの回帰確認用)
MIN_SYMBOLS_PER_SPLIT = 50                        # splitごとの記号の正解数の下限 (評価の分母を確保する)
MIN_WORDS_PER_SPLIT = 50                          # splitごとの普通の正解候補の下限 (損失の測定に必要)
MAX_SYMBOLS_PER_CASE = 3                          # 1ケースで期待する記号の上限 (候補の並びを単純に保つ)


def load_corpus() -> dict:
    """
    @brief コーパスのJSONを読み込む

    Returns:
        コーパスのトップレベル (version・description・cases・excluded)
    """
    return json.loads(CORPUS_PATH.read_text(encoding="utf-8"))


def load_dictionary_symbols() -> dict[str, list[str]]:
    """
    @brief 補助記号辞書から読みごとの記号の並びを読む

    Returns:
        読みをキー、辞書の行順の記号の並びを値とする辞書
    """
    symbols: dict[str, list[str]] = {}
    for line in DICTIONARY_PATH.read_text(encoding="utf-8").splitlines():
        if not line:
            continue
        reading, symbol, _ = line.split("\t")
        symbols.setdefault(reading, []).append(symbol)
    return symbols


def load_dictionary_tiers() -> dict[str, str]:
    """
    @brief 補助記号辞書から読みごとのtierを読む

    Returns:
        読みをキー、tier (AまたはB) を値とする辞書
    """
    tiers: dict[str, str] = {}
    for line in DICTIONARY_PATH.read_text(encoding="utf-8").splitlines():
        if not line:
            continue
        reading, _, tier = line.split("\t")
        tiers[reading] = tier
    return tiers


class CorpusSchemaTests(unittest.TestCase):
    """
    @brief トップレベルと各ケースのスキーマを固定する
    """

    @classmethod
    def setUpClass(cls) -> None:
        cls.corpus = load_corpus()

    def test_top_level_schema(self) -> None:
        self.assertEqual(self.corpus.get("version"), 1)
        self.assertIsInstance(self.corpus.get("description"), str)
        self.assertTrue(self.corpus["description"])
        self.assertIsInstance(self.corpus.get("cases"), list)
        self.assertTrue(self.corpus["cases"])
        self.assertIsInstance(self.corpus.get("excluded"), list)

    def test_case_schema(self) -> None:
        for case in self.corpus["cases"]:
            with self.subTest(case=case.get("id")):
                keys = set(case)
                self.assertTrue(REQUIRED_CASE_KEYS <= keys, keys)
                self.assertTrue(keys <= REQUIRED_CASE_KEYS | OPTIONAL_CASE_KEYS, keys)

                self.assertIsInstance(case["id"], str)
                self.assertRegex(case["id"], ID_PATTERN)
                self.assertIsInstance(case["reading"], str)
                self.assertIsInstance(case["context"], str)
                self.assertIn(case["tier"], TIERS)
                self.assertIn(case["split"], SPLITS)
                self.assertIsInstance(case["partialReadingConflict"], bool)
                if "notes" in case:
                    self.assertIsInstance(case["notes"], str)

                self.assertIsInstance(case["expectedSymbols"], list)
                self.assertLessEqual(len(case["expectedSymbols"]), MAX_SYMBOLS_PER_CASE)
                for symbol in case["expectedSymbols"]:
                    self.assertIsInstance(symbol, str)
                    self.assertTrue(symbol)
                self.assertIsInstance(case["expectedWords"], list)
                for word in case["expectedWords"]:
                    self.assertIsInstance(word, str)
                    self.assertTrue(word)

    def test_ids_are_unique(self) -> None:
        ids = [case["id"] for case in self.corpus["cases"]]
        self.assertEqual(len(ids), len(set(ids)))

    def test_readings_are_two_or_more_hiragana_with_long_vowel(self) -> None:
        for case in self.corpus["cases"]:
            with self.subTest(case=case["id"]):
                self.assertRegex(case["reading"], READING_PATTERN)

    def test_expected_symbols_are_unique_within_a_case(self) -> None:
        for case in self.corpus["cases"]:
            with self.subTest(case=case["id"]):
                self.assertEqual(
                    len(case["expectedSymbols"]), len(set(case["expectedSymbols"]))
                )

    def test_excluded_schema(self) -> None:
        for entry in self.corpus["excluded"]:
            with self.subTest(reading=entry.get("reading")):
                self.assertEqual(set(entry), REQUIRED_EXCLUDED_KEYS)
                self.assertIsInstance(entry["reading"], str)
                self.assertTrue(entry["reading"])
                self.assertIn(entry["reason"], EXCLUDED_REASONS)
                self.assertIsInstance(entry["notes"], str)


class CorpusContentTests(unittest.TestCase):
    """
    @brief split・tier・読みの採録規則を固定する
    """

    @classmethod
    def setUpClass(cls) -> None:
        cls.corpus = load_corpus()
        cls.cases = cls.corpus["cases"]

    def test_a_reading_belongs_to_a_single_split(self) -> None:
        split_by_reading: dict[str, str] = {}
        for case in self.cases:
            with self.subTest(case=case["id"]):
                self.assertEqual(
                    split_by_reading.setdefault(case["reading"], case["split"]),
                    case["split"],
                )

    def test_a_reading_keeps_a_single_tier(self) -> None:
        tier_by_reading: dict[str, str] = {}
        for case in self.cases:
            with self.subTest(case=case["id"]):
                self.assertEqual(
                    tier_by_reading.setdefault(case["reading"], case["tier"]),
                    case["tier"],
                )

    def test_both_splits_have_both_tiers(self) -> None:
        for split in SPLITS:
            with self.subTest(split=split):
                tiers = {case["tier"] for case in self.cases if case["split"] == split}
                self.assertEqual(tiers, set(TIERS))

    def test_split_totals_are_large_enough(self) -> None:
        for split in SPLITS:
            subset = [case for case in self.cases if case["split"] == split]
            with self.subTest(split=split):
                self.assertGreaterEqual(
                    sum(len(case["expectedSymbols"]) for case in subset),
                    MIN_SYMBOLS_PER_SPLIT,
                )
                self.assertGreaterEqual(
                    sum(len(case["expectedWords"]) for case in subset),
                    MIN_WORDS_PER_SPLIT,
                )

    def test_required_readings_are_present(self) -> None:
        readings = {case["reading"] for case in self.cases}
        for reading in REQUIRED_READINGS:
            with self.subTest(reading=reading):
                self.assertIn(reading, readings)

    def test_no_duplicate_reading_and_context_pair(self) -> None:
        pairs = [(case["reading"], case["context"]) for case in self.cases]
        self.assertEqual(len(pairs), len(set(pairs)))

    def test_excluded_readings_do_not_appear_in_cases(self) -> None:
        readings = {case["reading"] for case in self.cases}
        for entry in self.corpus["excluded"]:
            with self.subTest(reading=entry["reading"]):
                self.assertNotIn(entry["reading"], readings)

    def test_single_character_exclusions_are_one_character(self) -> None:
        for entry in self.corpus["excluded"]:
            if entry["reason"] == "single-character-reading":
                with self.subTest(reading=entry["reading"]):
                    self.assertEqual(len(entry["reading"]), 1)


class CorpusDictionaryTests(unittest.TestCase):
    """
    @brief コーパスのtierと記号の表記が辞書と整合することを固定する
    """

    @classmethod
    def setUpClass(cls) -> None:
        cls.corpus = load_corpus()
        cls.dictionary_symbols = load_dictionary_symbols()
        cls.dictionary_tiers = load_dictionary_tiers()

    def test_tier_matches_dictionary_or_defaults_to_b(self) -> None:
        for case in self.corpus["cases"]:
            with self.subTest(case=case["id"]):
                self.assertEqual(
                    case["tier"], self.dictionary_tiers.get(case["reading"], "B")
                )

    def test_expected_symbols_are_listed_for_the_reading(self) -> None:
        for case in self.corpus["cases"]:
            if not case["expectedSymbols"]:
                continue
            available = set(self.dictionary_symbols.get(case["reading"], []))
            with self.subTest(case=case["id"]):
                self.assertTrue(available, case["reading"])
                for symbol in case["expectedSymbols"]:
                    self.assertIn(symbol, available)


if __name__ == "__main__":
    unittest.main()
