import Foundation
import XCTest

@testable import hazkey_server

final class RelativeDateProviderTests: XCTestCase {

    // MARK: - Trigger detection (Day)

    func testDetectTriggerForAllDayWords() {
        XCTAssertEqual(RelativeDateProvider.detectTrigger(composingHiragana: "きょう")?.kanji, "今日")
        XCTAssertEqual(RelativeDateProvider.detectTrigger(composingHiragana: "きのう")?.kanji, "昨日")
        XCTAssertEqual(RelativeDateProvider.detectTrigger(composingHiragana: "おととい")?.kanji, "一昨日")
        XCTAssertEqual(RelativeDateProvider.detectTrigger(composingHiragana: "あした")?.kanji, "明日")
        XCTAssertEqual(RelativeDateProvider.detectTrigger(composingHiragana: "あす")?.kanji, "明日")
        XCTAssertEqual(RelativeDateProvider.detectTrigger(composingHiragana: "あさって")?.kanji, "明後日")
        XCTAssertEqual(RelativeDateProvider.detectTrigger(composingHiragana: "しあさって")?.kanji, "明々後日")
    }

    // MARK: - Trigger detection (Month)

    func testDetectTriggerForAllMonthWords() {
        XCTAssertEqual(RelativeDateProvider.detectTrigger(composingHiragana: "こんげつ")?.kanji, "今月")
        XCTAssertEqual(RelativeDateProvider.detectTrigger(composingHiragana: "らいげつ")?.kanji, "来月")
        XCTAssertEqual(RelativeDateProvider.detectTrigger(composingHiragana: "せんげつ")?.kanji, "先月")
    }

    // MARK: - Trigger detection (Month-end) [新規]

    func testDetectTriggerForAllMonthEndWords() {
        XCTAssertEqual(RelativeDateProvider.detectTrigger(composingHiragana: "げつまつ")?.kanji, "月末")
        XCTAssertEqual(RelativeDateProvider.detectTrigger(composingHiragana: "こんげつまつ")?.kanji, "今月末")
        XCTAssertEqual(RelativeDateProvider.detectTrigger(composingHiragana: "らいげつまつ")?.kanji, "来月末")
        XCTAssertEqual(RelativeDateProvider.detectTrigger(composingHiragana: "せんげつまつ")?.kanji, "先月末")
    }

    // MARK: - Trigger detection (Year)

    func testDetectTriggerForAllYearWords() {
        XCTAssertEqual(RelativeDateProvider.detectTrigger(composingHiragana: "ことし")?.kanji, "今年")
        XCTAssertEqual(RelativeDateProvider.detectTrigger(composingHiragana: "らいねん")?.kanji, "来年")
        XCTAssertEqual(RelativeDateProvider.detectTrigger(composingHiragana: "きょねん")?.kanji, "去年")
        XCTAssertEqual(RelativeDateProvider.detectTrigger(composingHiragana: "さらいねん")?.kanji, "再来年")
        XCTAssertEqual(RelativeDateProvider.detectTrigger(composingHiragana: "おととし")?.kanji, "一昨年")
    }

    // MARK: - Trigger detection (Year absolute) [新規]

    func testDetectTriggerForAllYearAbsoluteWords() {
        XCTAssertEqual(RelativeDateProvider.detectTrigger(composingHiragana: "ねんまつ")?.kanji, "年末")
        XCTAssertEqual(RelativeDateProvider.detectTrigger(composingHiragana: "おおみそか")?.kanji, "大晦日")
        XCTAssertEqual(RelativeDateProvider.detectTrigger(composingHiragana: "ねんし")?.kanji, "年始")
        XCTAssertEqual(RelativeDateProvider.detectTrigger(composingHiragana: "がんじつ")?.kanji, "元日")
    }

    func testDetectTriggerReturnsNilForNonMatch() {
        XCTAssertNil(RelativeDateProvider.detectTrigger(composingHiragana: ""))
        XCTAssertNil(RelativeDateProvider.detectTrigger(composingHiragana: "こんにちは"))
        XCTAssertNil(RelativeDateProvider.detectTrigger(composingHiragana: "きょうは"))
        XCTAssertNil(RelativeDateProvider.detectTrigger(composingHiragana: "Kyō"))
    }

    func testAshitaAndAsuBothMapToAshitaKanji() {
        let ashita = RelativeDateProvider.detectTrigger(composingHiragana: "あした")
        let asu = RelativeDateProvider.detectTrigger(composingHiragana: "あす")
        XCTAssertEqual(ashita?.kanji, "明日")
        XCTAssertEqual(asu?.kanji, "明日")
        // いずれも .day(offset: 1)
        if case .day(let offset) = ashita?.target {
            XCTAssertEqual(offset, 1)
        } else {
            XCTFail("あした should be .day target")
        }
        if case .day(let offset) = asu?.target {
            XCTAssertEqual(offset, 1)
        } else {
            XCTFail("あす should be .day target")
        }
    }

    // MARK: - DateTarget offset values

    func testDayTargetOffsets() {
        expectTarget(.day(offset:  0), for: "きょう")
        expectTarget(.day(offset: -1), for: "きのう")
        expectTarget(.day(offset: -2), for: "おととい")
        expectTarget(.day(offset:  1), for: "あした")
        expectTarget(.day(offset:  2), for: "あさって")
        expectTarget(.day(offset:  3), for: "しあさって")
    }

    func testMonthTargetOffsets() {
        expectTarget(.month(offset:  0), for: "こんげつ")
        expectTarget(.month(offset:  1), for: "らいげつ")
        expectTarget(.month(offset: -1), for: "せんげつ")
    }

    func testMonthEndTargetOffsets() {
        expectTarget(.monthEnd(offset:  0), for: "げつまつ")
        expectTarget(.monthEnd(offset:  0), for: "こんげつまつ")
        expectTarget(.monthEnd(offset:  1), for: "らいげつまつ")
        expectTarget(.monthEnd(offset: -1), for: "せんげつまつ")
    }

    func testYearTargetOffsets() {
        expectTarget(.year(offset:  0), for: "ことし")
        expectTarget(.year(offset:  1), for: "らいねん")
        expectTarget(.year(offset: -1), for: "きょねん")
        expectTarget(.year(offset:  2), for: "さらいねん")    // [新規]
        expectTarget(.year(offset: -2), for: "おととし")      // [新規]
    }

    func testYearAbsoluteTargets() {
        expectTarget(.yearAbsolute(month: 12, day: 31), for: "ねんまつ")
        expectTarget(.yearAbsolute(month: 12, day: 31), for: "おおみそか")
        expectTarget(.yearAbsolute(month:  1, day:  1), for: "ねんし")
        expectTarget(.yearAbsolute(month:  1, day:  1), for: "がんじつ")
    }

    // MARK: - Date generation: day granularity

    func testDayGranularityFormats() {
        // 2026-08-11 は火曜日
        let trigger = RelativeDateProvider.detectTrigger(composingHiragana: "きょう")!
        let now = Self.makeDate(year: 2026, month: 8, day: 11)!
        let result = RelativeDateProvider.generateDateStrings(for: trigger, now: now)

        // 6 patterns: 4 base + 2 曜日付き (西暦, 和暦)
        XCTAssertEqual(result.count, 6)
        XCTAssertEqual(result[0], "2026年8月11日")
        XCTAssertEqual(result[1], "2026-08-11")
        XCTAssertEqual(result[2], "2026/08/11")
        XCTAssertEqual(result[3], "令和8年8月11日")
        XCTAssertEqual(result[4], "2026年8月11日(火)")
        XCTAssertEqual(result[5], "令和8年8月11日(火)")
    }

    func testDayGranularityYesterday() {
        let trigger = RelativeDateProvider.detectTrigger(composingHiragana: "きのう")!
        let now = Self.makeDate(year: 2026, month: 8, day: 11)!
        let result = RelativeDateProvider.generateDateStrings(for: trigger, now: now)

        XCTAssertEqual(result[0], "2026年8月10日")
        XCTAssertEqual(result[1], "2026-08-10")
        XCTAssertEqual(result[2], "2026/08/10")
        XCTAssertEqual(result[3], "令和8年8月10日")
        XCTAssertEqual(result[4], "2026年8月10日(月)")  // 8/10 = Monday
        XCTAssertEqual(result[5], "令和8年8月10日(月)")
    }

    func testDayGranularityTomorrow() {
        let trigger = RelativeDateProvider.detectTrigger(composingHiragana: "あした")!
        let now = Self.makeDate(year: 2026, month: 8, day: 11)!
        let result = RelativeDateProvider.generateDateStrings(for: trigger, now: now)

        XCTAssertEqual(result[0], "2026年8月12日")
        XCTAssertEqual(result[4], "2026年8月12日(水)")  // 8/12 = Wednesday
    }

    func testDayGranularityShiasatteThreeDaysAhead() {
        let trigger = RelativeDateProvider.detectTrigger(composingHiragana: "しあさって")!
        let now = Self.makeDate(year: 2026, month: 8, day: 11)!
        let result = RelativeDateProvider.generateDateStrings(for: trigger, now: now)

        XCTAssertEqual(result[0], "2026年8月14日")
        XCTAssertEqual(result[1], "2026-08-14")
        XCTAssertEqual(result[4], "2026年8月14日(金)")  // 8/14 = Friday
    }

    func testDayGranularityCrossesMonthBoundary() {
        // 2026-08-31 + 1 day = 2026-09-01 (月またぎ)
        let trigger = RelativeDateProvider.detectTrigger(composingHiragana: "あした")!
        let now = Self.makeDate(year: 2026, month: 8, day: 31)!
        let result = RelativeDateProvider.generateDateStrings(for: trigger, now: now)

        XCTAssertEqual(result[0], "2026年9月1日")
        XCTAssertEqual(result[1], "2026-09-01")
        XCTAssertEqual(result[3], "令和8年9月1日")
        XCTAssertEqual(result[4], "2026年9月1日(火)")  // 9/1 = Tuesday
    }

    func testDayGranularityOtotoiTwoDaysBack() {
        let trigger = RelativeDateProvider.detectTrigger(composingHiragana: "おととい")!
        let now = Self.makeDate(year: 2026, month: 8, day: 1)!
        let result = RelativeDateProvider.generateDateStrings(for: trigger, now: now)

        // 2026-08-01 - 2 days = 2026-07-30
        XCTAssertEqual(result[0], "2026年7月30日")
        XCTAssertEqual(result[1], "2026-07-30")
    }

    // MARK: - Date generation: month granularity (曜日なし)

    func testMonthGranularityFormatsForCurrentMonth() {
        let trigger = RelativeDateProvider.detectTrigger(composingHiragana: "こんげつ")!
        let now = Self.makeDate(year: 2026, month: 8, day: 11)!
        let result = RelativeDateProvider.generateDateStrings(for: trigger, now: now)

        // 4 patterns (曜日なし)
        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(result[0], "2026年8月")
        XCTAssertEqual(result[1], "2026-08")
        XCTAssertEqual(result[2], "2026/08")
        XCTAssertEqual(result[3], "令和8年8月")
    }

    func testMonthGranularityRaigetsuNextMonth() {
        let trigger = RelativeDateProvider.detectTrigger(composingHiragana: "らいげつ")!
        let now = Self.makeDate(year: 2026, month: 8, day: 11)!
        let result = RelativeDateProvider.generateDateStrings(for: trigger, now: now)

        XCTAssertEqual(result[0], "2026年9月")
        XCTAssertEqual(result[3], "令和8年9月")
    }

    func testMonthGranularityCrossesYearBoundary() {
        // 2026-12 + 1 month = 2027-01
        let trigger = RelativeDateProvider.detectTrigger(composingHiragana: "らいげつ")!
        let now = Self.makeDate(year: 2026, month: 12, day: 15)!
        let result = RelativeDateProvider.generateDateStrings(for: trigger, now: now)

        XCTAssertEqual(result[0], "2027年1月")
        XCTAssertEqual(result[1], "2027-01")
    }

    func testMonthGranularityAvoidsMonthOverflowFromEndOfMonth() {
        // 2026-01-31 + 1 month: 月末オーバーフロー回避のため day=1 で計算
        let trigger = RelativeDateProvider.detectTrigger(composingHiragana: "らいげつ")!
        let now = Self.makeDate(year: 2026, month: 1, day: 31)!
        let result = RelativeDateProvider.generateDateStrings(for: trigger, now: now)

        XCTAssertEqual(result[0], "2026年2月")
    }

    // MARK: - Date generation: monthEnd granularity [新規]

    func testMonthEndGranularityFormatsForCurrentMonthEnd() {
        // 2026年8月 → 8月31日 (月曜日)
        let trigger = RelativeDateProvider.detectTrigger(composingHiragana: "げつまつ")!
        let now = Self.makeDate(year: 2026, month: 8, day: 11)!
        let result = RelativeDateProvider.generateDateStrings(for: trigger, now: now)

        // 6 patterns (day と同じ)
        XCTAssertEqual(result.count, 6)
        XCTAssertEqual(result[0], "2026年8月31日")
        XCTAssertEqual(result[1], "2026-08-31")
        XCTAssertEqual(result[2], "2026/08/31")
        XCTAssertEqual(result[3], "令和8年8月31日")
        XCTAssertEqual(result[4], "2026年8月31日(月)")
        XCTAssertEqual(result[5], "令和8年8月31日(月)")
    }

    func testMonthEndThisMonthEndSameAsGetsumatsu() {
        // げつまつ と こんげつまつ は同じ結果
        let now = Self.makeDate(year: 2026, month: 8, day: 11)!
        let r1 = RelativeDateProvider.generateDateStrings(
            for: RelativeDateProvider.detectTrigger(composingHiragana: "げつまつ")!, now: now)
        let r2 = RelativeDateProvider.generateDateStrings(
            for: RelativeDateProvider.detectTrigger(composingHiragana: "こんげつまつ")!, now: now)
        XCTAssertEqual(r1, r2)
    }

    func testMonthEndNextMonthHandlesShortMonth() {
        // 2026年1月 → 来月末 = 2026年2月28日 (2026年は平年、うるう年でない)
        let trigger = RelativeDateProvider.detectTrigger(composingHiragana: "らいげつまつ")!
        let now = Self.makeDate(year: 2026, month: 1, day: 15)!
        let result = RelativeDateProvider.generateDateStrings(for: trigger, now: now)

        XCTAssertEqual(result[0], "2026年2月28日")
        XCTAssertEqual(result[1], "2026-02-28")
    }

    func testMonthEndLeapYearFebruary() {
        // 2024年1月 → 来月末 = 2024年2月29日 (2024年はうるう年)
        let trigger = RelativeDateProvider.detectTrigger(composingHiragana: "らいげつまつ")!
        let now = Self.makeDate(year: 2024, month: 1, day: 15)!
        let result = RelativeDateProvider.generateDateStrings(for: trigger, now: now)

        XCTAssertEqual(result[0], "2024年2月29日")
        XCTAssertEqual(result[1], "2024-02-29")
    }

    func testMonthEndLastMonth() {
        // 2026年8月 → 先月末 = 2026年7月31日
        let trigger = RelativeDateProvider.detectTrigger(composingHiragana: "せんげつまつ")!
        let now = Self.makeDate(year: 2026, month: 8, day: 11)!
        let result = RelativeDateProvider.generateDateStrings(for: trigger, now: now)

        XCTAssertEqual(result[0], "2026年7月31日")
    }

    func testMonthEndDecember() {
        // 2026年12月末 = 2026年12月31日
        let trigger = RelativeDateProvider.detectTrigger(composingHiragana: "げつまつ")!
        let now = Self.makeDate(year: 2026, month: 12, day: 15)!
        let result = RelativeDateProvider.generateDateStrings(for: trigger, now: now)

        XCTAssertEqual(result[0], "2026年12月31日")
    }

    // MARK: - Date generation: year granularity (曜日なし)

    func testYearGranularityFormatsForCurrentYear() {
        let trigger = RelativeDateProvider.detectTrigger(composingHiragana: "ことし")!
        let now = Self.makeDate(year: 2026, month: 8, day: 11)!
        let result = RelativeDateProvider.generateDateStrings(for: trigger, now: now)

        // 2 patterns (曜日なし)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0], "2026年")
        XCTAssertEqual(result[1], "令和8年")
    }

    func testYearGranularitySarainen() {
        // [新規] 再来年
        let trigger = RelativeDateProvider.detectTrigger(composingHiragana: "さらいねん")!
        let now = Self.makeDate(year: 2026, month: 8, day: 11)!
        let result = RelativeDateProvider.generateDateStrings(for: trigger, now: now)

        XCTAssertEqual(result[0], "2028年")
        XCTAssertEqual(result[1], "令和10年")
    }

    func testYearGranularityOtotoshi() {
        // [新規] 一昨年
        let trigger = RelativeDateProvider.detectTrigger(composingHiragana: "おととし")!
        let now = Self.makeDate(year: 2026, month: 8, day: 11)!
        let result = RelativeDateProvider.generateDateStrings(for: trigger, now: now)

        XCTAssertEqual(result[0], "2024年")
        XCTAssertEqual(result[1], "令和6年")
    }

    // MARK: - Date generation: yearAbsolute granularity [新規]

    func testYearAbsoluteNenmatsu() {
        // 当年の 12/31 (年末)
        let trigger = RelativeDateProvider.detectTrigger(composingHiragana: "ねんまつ")!
        let now = Self.makeDate(year: 2026, month: 8, day: 11)!
        let result = RelativeDateProvider.generateDateStrings(for: trigger, now: now)

        XCTAssertEqual(result.count, 6)
        XCTAssertEqual(result[0], "2026年12月31日")
        XCTAssertEqual(result[1], "2026-12-31")
        XCTAssertEqual(result[2], "2026/12/31")
        XCTAssertEqual(result[3], "令和8年12月31日")
        XCTAssertEqual(result[4], "2026年12月31日(木)")  // 12/31 = Thursday
        XCTAssertEqual(result[5], "令和8年12月31日(木)")
    }

    func testYearAbsoluteOomisokaSameAsNenmatsu() {
        // ねんまつ と おおみそか は同じ日付 (12/31)、漢字表現のみ異なる
        let now = Self.makeDate(year: 2026, month: 8, day: 11)!
        let r1 = RelativeDateProvider.generateDateStrings(
            for: RelativeDateProvider.detectTrigger(composingHiragana: "ねんまつ")!, now: now)
        let r2 = RelativeDateProvider.generateDateStrings(
            for: RelativeDateProvider.detectTrigger(composingHiragana: "おおみそか")!, now: now)
        XCTAssertEqual(r1, r2)
    }

    func testYearAbsoluteNenshi() {
        // 当年の 1/1 (年始)
        let trigger = RelativeDateProvider.detectTrigger(composingHiragana: "ねんし")!
        let now = Self.makeDate(year: 2026, month: 8, day: 11)!
        let result = RelativeDateProvider.generateDateStrings(for: trigger, now: now)

        XCTAssertEqual(result[0], "2026年1月1日")
        XCTAssertEqual(result[1], "2026-01-01")
        XCTAssertEqual(result[3], "令和8年1月1日")
        XCTAssertEqual(result[4], "2026年1月1日(木)")  // 1/1 = Thursday
    }

    func testYearAbsoluteGanjitsuSameAsNenshi() {
        // ねんし と がんじつ は同じ日付 (1/1)
        let now = Self.makeDate(year: 2026, month: 8, day: 11)!
        let r1 = RelativeDateProvider.generateDateStrings(
            for: RelativeDateProvider.detectTrigger(composingHiragana: "ねんし")!, now: now)
        let r2 = RelativeDateProvider.generateDateStrings(
            for: RelativeDateProvider.detectTrigger(composingHiragana: "がんじつ")!, now: now)
        XCTAssertEqual(r1, r2)
    }

    // MARK: - 曜日 calculation correctness

    func testWeekdayCalculationKnownDates() {
        // 既知の曜日で検証
        // 2024-01-01 = 月曜日
        XCTAssertEqual(Self.weekdayString(year: 2024, month: 1, day: 1), "月")
        // 2024-01-07 = 日曜日
        XCTAssertEqual(Self.weekdayString(year: 2024, month: 1, day: 7), "日")
        // 2024-01-06 = 土曜日
        XCTAssertEqual(Self.weekdayString(year: 2024, month: 1, day: 6), "土")
        // 2026-08-11 = 火曜日
        XCTAssertEqual(Self.weekdayString(year: 2026, month: 8, day: 11), "火")
    }

    // MARK: - Era boundary (元号切り替え)

    func testEraBoundaryHeiseiLastDayToReiwaFirstDay() {
        // 2019-04-30 = 平成31年4月30日 (火曜日、平成最終日)
        // 2019-05-01 = 令和元年5月1日 (水曜日、令和初日)
        let heiseiLastDay = RelativeDateProvider.detectTrigger(composingHiragana: "きょう")!
        let result1 = RelativeDateProvider.generateDateStrings(
            for: heiseiLastDay, now: Self.makeDate(year: 2019, month: 4, day: 30)!)
        XCTAssertEqual(result1[0], "2019年4月30日")
        XCTAssertEqual(result1[3], "平成31年4月30日")
        XCTAssertEqual(result1[4], "2019年4月30日(火)")

        let reiwaFirstDay = RelativeDateProvider.detectTrigger(composingHiragana: "きょう")!
        let result2 = RelativeDateProvider.generateDateStrings(
            for: reiwaFirstDay, now: Self.makeDate(year: 2019, month: 5, day: 1)!)
        XCTAssertEqual(result2[0], "2019年5月1日")
        XCTAssertEqual(result2[3], "令和元年5月1日")  // DateFormatter は元年表記
        XCTAssertEqual(result2[4], "2019年5月1日(水)")
    }

    func testEraBoundaryTomorrowCrossesFromHeiseiToReiwa() {
        // 2019-04-30 の「明日」= 2019-05-01 (令和元年5月1日・水曜日)
        let trigger = RelativeDateProvider.detectTrigger(composingHiragana: "あした")!
        let result = RelativeDateProvider.generateDateStrings(
            for: trigger, now: Self.makeDate(year: 2019, month: 4, day: 30)!)

        XCTAssertEqual(result[0], "2019年5月1日")
        XCTAssertEqual(result[3], "令和元年5月1日")
        XCTAssertEqual(result[4], "2019年5月1日(水)")
    }

    // MARK: - Output format sanity

    func testDayOutputOrderMatchesSpec() {
        // 仕様: yyyy年M月d日 / yyyy-MM-dd / yyyy/MM/dd / Gy年M月d日 /
        //       yyyy年M月d日(曜日) / Gy年M月d日(曜日)
        let trigger = RelativeDateProvider.detectTrigger(composingHiragana: "きょう")!
        let result = RelativeDateProvider.generateDateStrings(
            for: trigger, now: Self.makeDate(year: 2026, month: 8, day: 11)!)

        XCTAssertEqual(result.count, 6)
        XCTAssertTrue(result[0].contains("年") && result[0].contains("月") && result[0].contains("日"))
        XCTAssertEqual(result[1].split(separator: "-").count, 3)
        XCTAssertEqual(result[2].split(separator: "/").count, 3)
        XCTAssertTrue(result[3].hasPrefix("令和"))
        // 曜日付きは括弧で囲まれた1文字曜日を末尾に持つ
        XCTAssertTrue(result[4].hasSuffix("(火)"))
        XCTAssertTrue(result[5].hasPrefix("令和") && result[5].hasSuffix("(火)"))
    }

    func testMonthOutputOrderMatchesSpec() {
        // 仕様: yyyy年M月 / yyyy-MM / yyyy/MM / Gy年M月 (曜日なし)
        let trigger = RelativeDateProvider.detectTrigger(composingHiragana: "こんげつ")!
        let result = RelativeDateProvider.generateDateStrings(
            for: trigger, now: Self.makeDate(year: 2026, month: 8, day: 11)!)

        XCTAssertEqual(result.count, 4)
        XCTAssertTrue(result[0].contains("年") && result[0].contains("月"))
        XCTAssertFalse(result[0].contains("日"))  // 月単位なので日なし
        XCTAssertFalse(result[0].contains("("))  // 曜日なし
    }

    func testYearOutputOrderMatchesSpec() {
        // 仕様: yyyy年 / Gy年 (曜日なし)
        let trigger = RelativeDateProvider.detectTrigger(composingHiragana: "ことし")!
        let result = RelativeDateProvider.generateDateStrings(
            for: trigger, now: Self.makeDate(year: 2026, month: 8, day: 11)!)

        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result[0].hasSuffix("年"))
        XCTAssertFalse(result[0].contains("月") || result[0].contains("日"))
        XCTAssertTrue(result[1].hasPrefix("令和") && result[1].hasSuffix("年"))
    }

    // MARK: - Trigger table completeness

    func testAllTriggersHaveNonEmptyKanjiAndReading() {
        for trigger in RelativeDateProvider.triggers {
            XCTAssertFalse(trigger.reading.isEmpty, "Trigger reading must not be empty")
            XCTAssertFalse(trigger.kanji.isEmpty, "Trigger kanji must not be empty")
        }
    }

    func testAllTriggersUseOnlyHiraganaReadings() {
        for trigger in RelativeDateProvider.triggers {
            for char in trigger.reading {
                let scalar = char.unicodeScalars.first!.value
                // ひらがなコードポイント範囲: U+3040-U+309F
                XCTAssertTrue(
                    scalar >= 0x3040 && scalar <= 0x309F,
                    "Trigger reading '\(trigger.reading)' must be hiragana only (found U+\(String(format: "%04X", scalar)))"
                )
            }
        }
    }

    func testAllTriggersHaveUniqueReadingKanjiPairs() {
        // 同じ (reading, kanji) ペアが重複しないこと
        var seen = Set<String>()
        for trigger in RelativeDateProvider.triggers {
            let key = "\(trigger.reading)|\(trigger.kanji)"
            XCTAssertFalse(seen.contains(key), "Duplicate trigger: \(key)")
            seen.insert(key)
        }
    }

    func testTriggerCount() {
        // 期待されるトリガー数: 7 day + 3 month + 4 monthEnd + 5 year + 4 yearAbsolute = 23
        XCTAssertEqual(RelativeDateProvider.triggers.count, 23)
    }

    // MARK: - Helpers

    private func expectTarget(_ expected: RelativeDateProvider.DateTarget, for reading: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        let trigger = RelativeDateProvider.detectTrigger(composingHiragana: reading)
        XCTAssertNotNil(trigger, "Trigger not found for \(reading)", file: file, line: line)
        XCTAssertEqual(trigger?.target, expected, "Wrong target for \(reading)", file: file, line: line)
    }

    /// 決定論的テストのため、Tokyo timezoneで指定年月日の Date を生成する。
    private static func makeDate(year: Int, month: Int, day: Int) -> Date? {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = 12  // 正午 (DST境界のエッジケース回避)
        comps.timeZone = TimeZone(identifier: "Asia/Tokyo")
        let calendar = Calendar(identifier: .gregorian)
        return calendar.date(from: comps)
    }

    /// テスト用: 指定日の曜日漢字を取得 (実装の private 関数と同じロジック)。
    private static func weekdayString(year: Int, month: Int, day: Int) -> String {
        guard let date = makeDate(year: year, month: month, day: day) else { return "" }
        let kanji = ["日", "月", "火", "水", "木", "金", "土"]
        let weekday = Calendar(identifier: .gregorian).component(.weekday, from: date)
        return kanji[weekday - 1]
    }
}
