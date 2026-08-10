import Foundation

/// Provides dynamic date candidates for relative-date trigger words.
///
/// トリガーワード (`きょう`, `きのう`, `あした`, `こんげつ`, `ことし`, `げつまつ`,
/// `ねんまつ`, 等) を入力ひらがなと完全一致で検出する。エンジンが対応する漢字表現
/// (例: `今日`) を候補として返した場合、現在日時に基づいて計算した日付文字列を
/// 漢字表現の直後に挿入する。
///
/// 出力フォーマット (target に依存):
///   - day / monthEnd / yearAbsolute:
///       `yyyy年M月d日` / `yyyy-MM-dd` / `yyyy/MM/dd` / `Gy年M月d日` (和暦) /
///       `yyyy年M月d日(曜日)` / `Gy年M月d日(曜日)` (和暦+曜日)
///   - month: `yyyy年M月` / `yyyy-MM` / `yyyy/MM` / `Gy年M月` (和暦)
///   - year:  `yyyy年` / `Gy年` (和暦)
///
/// 和暦は `Calendar(identifier: .japanese)` を使用し、元号境界 (例: 2019-04-30
/// 平成 → 2019-05-01 令和) を自動処理する。元号の初年は DateFormatter 標準動作に
/// より「元年」と表記される。
enum RelativeDateProvider {

    /// 計算対象とオフセットを表す。
    enum DateTarget: Equatable {
        /// 日単位の相対指定 (例: 今日=0, 昨日=-1, 明日=+1)。出力は年月日+曜日。
        case day(offset: Int)
        /// 月単位の相対指定 (例: 今月=0, 先月=-1, 来月=+1)。出力は年月のみ。
        case month(offset: Int)
        /// 年単位の相対指定 (例: 今年=0, 去年=-1, 来年=+1)。出力は年のみ。
        case year(offset: Int)
        /// 月末の相対指定 (例: 月末=0, 来月末=+1, 先月末=-1)。
        /// 対象月の最終日を計算して出力する (年月日+曜日)。
        case monthEnd(offset: Int)
        /// 当年内の固定月日 (例: 年末=(12,31), 年始=(1,1))。出力は年月日+曜日。
        case yearAbsolute(month: Int, day: Int)
    }

    /// A trigger word that activates date candidate injection.
    struct Trigger: Equatable {
        /// ひらがなの読み (`composingText.toHiragana()` と完全一致で判定)。
        let reading: String
        /// エンジンが返す漢字表現。この候補の直後に日付文字列を挿入する。
        let kanji: String
        let target: DateTarget
    }

    /// All trigger words recognized by this provider.
    /// 読みの重複 (例: あした/あす → 明日) は別トリガーとして登録する。
    static let triggers: [Trigger] = [
        // === 日単位 ===
        Trigger(reading: "きょう",      kanji: "今日",    target: .day(offset:  0)),
        Trigger(reading: "きのう",      kanji: "昨日",    target: .day(offset: -1)),
        Trigger(reading: "おととい",    kanji: "一昨日",  target: .day(offset: -2)),
        Trigger(reading: "あした",      kanji: "明日",    target: .day(offset:  1)),
        Trigger(reading: "あす",        kanji: "明日",    target: .day(offset:  1)),
        Trigger(reading: "あさって",    kanji: "明後日",  target: .day(offset:  2)),
        Trigger(reading: "しあさって",  kanji: "明々後日", target: .day(offset:  3)),
        // === 月単位 (年月のみ出力) ===
        Trigger(reading: "こんげつ",    kanji: "今月",    target: .month(offset:  0)),
        Trigger(reading: "らいげつ",    kanji: "来月",    target: .month(offset:  1)),
        Trigger(reading: "せんげつ",    kanji: "先月",    target: .month(offset: -1)),
        // === 月末 (年月日+曜日を出力) ===
        Trigger(reading: "げつまつ",     kanji: "月末",    target: .monthEnd(offset:  0)),
        Trigger(reading: "こんげつまつ", kanji: "今月末",  target: .monthEnd(offset:  0)),
        Trigger(reading: "らいげつまつ", kanji: "来月末",  target: .monthEnd(offset:  1)),
        Trigger(reading: "せんげつまつ", kanji: "先月末",  target: .monthEnd(offset: -1)),
        // === 年単位 (年のみ出力) ===
        Trigger(reading: "ことし",      kanji: "今年",    target: .year(offset:  0)),
        Trigger(reading: "らいねん",    kanji: "来年",    target: .year(offset:  1)),
        Trigger(reading: "きょねん",    kanji: "去年",    target: .year(offset: -1)),
        Trigger(reading: "さらいねん",  kanji: "再来年",  target: .year(offset:  2)),
        Trigger(reading: "おととし",    kanji: "一昨年",  target: .year(offset: -2)),
        // === 年内の固定月日 (当年の特定日) ===
        Trigger(reading: "ねんまつ",    kanji: "年末",    target: .yearAbsolute(month: 12, day: 31)),
        Trigger(reading: "おおみそか",  kanji: "大晦日",  target: .yearAbsolute(month: 12, day: 31)),
        Trigger(reading: "ねんし",      kanji: "年始",    target: .yearAbsolute(month:  1, day:  1)),
        Trigger(reading: "がんじつ",    kanji: "元日",    target: .yearAbsolute(month:  1, day:  1)),
    ]

    /// Detect a trigger matching the composing hiragana exactly.
    /// Returns nil if no match (caller should not inject date candidates).
    static func detectTrigger(composingHiragana: String) -> Trigger? {
        return triggers.first { $0.reading == composingHiragana }
    }

    /// Generate formatted date strings for the trigger, in display order.
    /// - Parameter now: Inject `Date` for testing; defaults to current date.
    /// - Returns: Empty array if date computation fails (should not happen).
    static func generateDateStrings(for trigger: Trigger, now: Date = Date()) -> [String] {
        let calendar = Calendar(identifier: .gregorian)

        switch trigger.target {
        case .day(let offset):
            guard let date = calendar.date(byAdding: .day, value: offset, to: now) else {
                return []
            }
            return fullDateFormats(date: date, calendar: calendar)

        case .month(let offset):
            // day=1 で計算し、月末オーバーフロー (1月31日 + 1ヶ月等) を回避する。
            var baseComps = calendar.dateComponents([.year, .month], from: now)
            baseComps.day = 1
            guard let baseDate = calendar.date(from: baseComps),
                  let date = calendar.date(byAdding: .month, value: offset, to: baseDate)
            else {
                return []
            }
            return monthOnlyFormats(date: date)

        case .year(let offset):
            var baseComps = calendar.dateComponents([.year], from: now)
            baseComps.month = 1
            baseComps.day = 1
            guard let baseDate = calendar.date(from: baseComps),
                  let date = calendar.date(byAdding: .year, value: offset, to: baseDate)
            else {
                return []
            }
            return yearOnlyFormats(date: date)

        case .monthEnd(let offset):
            var baseComps = calendar.dateComponents([.year, .month], from: now)
            baseComps.day = 1
            guard let baseDate = calendar.date(from: baseComps),
                  let monthDate = calendar.date(byAdding: .month, value: offset, to: baseDate),
                  let range = calendar.range(of: .day, in: .month, for: monthDate)
            else {
                return []
            }
            // 当該月の最終日を組み立てる。range.count がその月の日数。
            var lastDayComps = calendar.dateComponents([.year, .month], from: monthDate)
            lastDayComps.day = range.count
            guard let date = calendar.date(from: lastDayComps) else { return [] }
            return fullDateFormats(date: date, calendar: calendar)

        case .yearAbsolute(let absMonth, let absDay):
            var baseComps = calendar.dateComponents([.year], from: now)
            baseComps.month = absMonth
            baseComps.day = absDay
            guard let date = calendar.date(from: baseComps) else { return [] }
            return fullDateFormats(date: date, calendar: calendar)
        }
    }

    // MARK: - Format builders

    /// 年月日(+曜日)の6形式を返す。
    /// 曜日付きバリアントはビジネス文書で一般的な "(火)" 形式。
    private static func fullDateFormats(date: Date, calendar: Calendar) -> [String] {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = comps.year, let month = comps.month, let day = comps.day else {
            return []
        }
        let weekdayStr = weekdayKanji(for: date)
        let wareki = formatWareki(date: date, dateFormat: "Gy年M月d日")
        return [
            "\(year)年\(month)月\(day)日",
            String(format: "%04d-%02d-%02d", year, month, day),
            String(format: "%04d/%02d/%02d", year, month, day),
            wareki,
            "\(year)年\(month)月\(day)日(\(weekdayStr))",
            "\(wareki)(\(weekdayStr))",
        ]
    }

    /// 年月の4形式を返す (曜日なし)。
    private static func monthOnlyFormats(date: Date) -> [String] {
        let calendar = Calendar(identifier: .gregorian)
        let comps = calendar.dateComponents([.year, .month], from: date)
        guard let year = comps.year, let month = comps.month else { return [] }
        return [
            "\(year)年\(month)月",
            String(format: "%04d-%02d", year, month),
            String(format: "%04d/%02d", year, month),
            formatWareki(date: date, dateFormat: "Gy年M月"),
        ]
    }

    /// 年の2形式を返す。
    private static func yearOnlyFormats(date: Date) -> [String] {
        let calendar = Calendar(identifier: .gregorian)
        let comps = calendar.dateComponents([.year], from: date)
        guard let year = comps.year else { return [] }
        return [
            "\(year)年",
            formatWareki(date: date, dateFormat: "Gy年"),
        ]
    }

    // MARK: - Helpers

    /// 曜日を表す漢字 (1文字)。Calendar.component(.weekday) は 1=日曜 ... 7=土曜。
    private static let weekdayKanjiArray = ["日", "月", "火", "水", "木", "金", "土"]

    /// 指定日付の曜日漢字を返す (例: "火")。
    private static func weekdayKanji(for date: Date) -> String {
        let weekday = Calendar(identifier: .gregorian).component(.weekday, from: date)
        // 1=Sunday ... 7=Saturday → 0-indexed
        guard weekday >= 1 && weekday <= 7 else { return "" }
        return weekdayKanjiArray[weekday - 1]
    }

    /// 和暦文字列を生成する。`Calendar(identifier: .japanese)` と `DateFormatter`
    /// を使用し、元号境界を自動処理する。元号初年は「元年」と表記される
    /// (DateFormatter 標準動作)。
    private static func formatWareki(date: Date, dateFormat: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .japanese)
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = dateFormat
        return formatter.string(from: date)
    }
}
