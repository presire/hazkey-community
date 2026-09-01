import Foundation

enum CandidateRequest {
    case full(numCandidatesPerPage: Int32? = nil, dateCandidatesAt: Int? = nil)
    case suggestion
    case prefix(cursorOffset: Int)
}

struct CorpusFixture {
    let name: String
    let reading: String
    let request: CandidateRequest
    let expectedCandidates: [String]
    let committedCandidate: String?
    let expectedComposingTextAfterCommit: String?
}

enum CorpusFixtures {
    static let fullConversion = CorpusFixture(
        name: "full-conversion",
        reading: "にほん",
        request: .full(),
        expectedCandidates: [
            "日本", "2本", "二本", "ニホン", "に本", "二ホン", "ニ本", "仁本", "仁保ん", "尼本",
            "にほん", "ﾆﾎﾝ", "二歩", "仁保", "にほ", "に", "二", "似", "煮", "仁",
            "ニ", "丹", "尼", "2", "荷", "ⅱ", "弐", "肖", "ニ゙", "②",
            "に゙", "に゚", "ニ゚", "珥", "貮", "怩", "新", "児", "尓", "迩",
            "爾", "姫", "貳", "西", "迯", "逃", "邇", "膩", "轜", "弍",
            "兒", "日"
        ],
        committedCandidate: nil,
        expectedComposingTextAfterCommit: nil)

    static let suggestion = CorpusFixture(
        name: "suggestion",
        reading: "にほん",
        request: .suggestion,
        expectedCandidates: [
            "日本語", "日本史", "日本語で"
        ],
        committedCandidate: nil,
        expectedComposingTextAfterCommit: nil)

    static let prefixConversion = CorpusFixture(
        name: "prefix-conversion",
        reading: "にほんご",
        request: .prefix(cursorOffset: -1),
        expectedCandidates: [
            "日本", "2本", "二本", "ニホン", "に本", "二ホン", "ニ本", "仁本", "仁保ん", "尼本",
            "にほん", "ﾆﾎﾝ", "二歩", "仁保", "にほ", "に", "二", "似", "煮", "仁",
            "ニ", "丹", "尼", "2", "荷", "ⅱ", "弐", "肖", "ニ゙", "②",
            "に゙", "に゚", "ニ゚", "珥", "貮", "怩", "新", "児", "尓", "迩",
            "爾", "姫", "貳", "西", "迯", "逃", "邇", "膩", "轜", "弍",
            "兒", "日"
        ],
        committedCandidate: nil,
        expectedComposingTextAfterCommit: nil)

    static let kanaNumber = CorpusFixture(
        name: "kana-number",
        reading: "にじゅう",
        request: .full(),
        expectedCandidates: [
            "二重", "廿", "二十", "20", "₂₀", "²⁰", "⑳", "⒇", "⒛", "に重",
            "二獣", "ニ獣", "二じゅう", "二中", "に中", "ニジュウ", "にじゅう", "ﾆｼﾞｭｳ", "にじゅ", "二豎",
            "二次", "2次", "虹", "2時", "にじ", "二時", "二字", "尼寺", "ニ次", "🌈",
            "ニジ", "🕑", "躪", "霓", "に", "二", "似", "煮", "仁", "ニ",
            "丹", "尼", "2", "荷", "ⅱ", "弐", "肖", "ニ゙", "②", "に゙",
            "に゚", "ニ゚", "珥", "貮", "怩", "新", "児", "尓", "迩", "爾",
            "姫", "貳", "西", "迯", "逃", "邇", "膩", "轜", "弍", "兒",
            "日"
        ],
        committedCandidate: nil,
        expectedComposingTextAfterCommit: nil)

    static let relativeDate = CorpusFixture(
        name: "relative-date",
        reading: "きょう",
        request: .full(numCandidatesPerPage: 1, dateCandidatesAt: 1),
        expectedCandidates: [
            "今日", "きょう", "境", "教", "橋", "京", "卿", "経", "興", "巨",
            "強", "恭", "鏡", "協", "共", "狂", "姜", "供", "響", "キョウ",
            "夾", "匡", "凶", "杏", "香", "峡", "饗", "挟", "ｷｮｳ", "狭",
            "龔", "況", "喬", "羌", "僑", "俠", "怯", "峽", "景", "皎",
            "脇", "兄", "經", "矜", "兇", "莢", "疆", "冏", "筴", "哽",
            "窖", "薑", "襁", "抂", "礦", "驕", "恊", "竟", "况", "烱",
            "皀", "秬", "挾", "僵", "鵁", "郷", "鞏", "羮", "夐", "轎",
            "梗", "竅", "峺", "亰", "脅", "呷", "蛩", "兢", "鋏", "韮",
            "磬", "逕", "敬", "蕎", "鄕", "畊", "剄", "摎", "刧", "侠",
            "匈", "狹", "暁", "恐", "澆", "洶", "徼", "享", "烋", "跫",
            "竸", "曉", "慊", "亨", "餃", "競", "蛬", "嬌", "梟", "嚮",
            "驚", "誑", "彊", "恟", "胸", "叫", "鏗", "矯", "袷", "陜",
            "筺", "驍", "磽", "篋", "繦", "居", "虚", "挙", "許", "キョ",
            "莒", "炬", "渠", "距", "舉", "墟", "鋸", "虛", "圭", "醵",
            "遽", "拠", "據", "踞", "歔", "裾", "擧", "倨", "去", "拒",
            "き", "来", "気", "機", "期", "着", "切", "器", "騎", "記",
            "稀", "木", "キ", "斬", "貴", "基", "樹", "季", "旗", "希",
            "黄", "忌", "帰", "伐", "規", "奇", "喜", "城", "軌", "既",
            "几", "岐", "葱", "癸", "鬼", "姫", "斫", "生", "危", "祺",
            "郗", "紀", "起", "氣", "驥", "綺", "桅", "汽", "揆", "簋",
            "柝", "圻", "伎", "畿", "き゚", "キ゚", "沂", "利", "亜", "藝",
            "榿", "水", "祈", "冀", "亀", "唏", "飢", "稘", "衣", "掎",
            "哉", "聴", "毅", "朞", "杞", "瞶", "竒", "徽", "龜", "悸",
            "揮", "矩", "屓", "曁", "箕", "饑", "寄", "棋", "甲", "己",
            "公", "煕", "餽", "智", "歸", "羇", "耆", "枳", "輝", "决",
            "覊", "逵", "卉", "棄", "敷", "黃", "饋", "馗", "欷", "曦",
            "諱", "譏", "妃", "明", "嘉", "匱", "覬", "跂", "蠣", "弃",
            "崎", "畸", "聆", "淇", "棊", "鐫", "企", "鑚", "禧", "喟",
            "效", "熈", "机", "皈", "亟", "麒", "窺", "幾", "決", "北",
            "騏", "刄", "燬", "麾", "僖", "聽", "憙", "吉", "羈", "籏",
            "詭", "嬉", "槎", "桔", "燹", "虧", "晞", "次", "暉", "簣",
            "亞", "効", "鎮", "善", "剞", "夬", "咥", "愧", "消", "蛎",
            "跪", "熙", "杵", "刋", "其", "置", "豈", "噐", "熹", "毀",
            "聞", "來"
        ],
        committedCandidate: nil,
        expectedComposingTextAfterCommit: nil)

    static let nonLearnableCommit = CorpusFixture(
        name: "non-learnable-kana-number-commit",
        reading: "にじゅう",
        request: .full(),
        expectedCandidates: [
            "二重", "廿", "二十", "20", "₂₀", "²⁰", "⑳", "⒇", "⒛", "に重",
            "二獣", "ニ獣", "二じゅう", "二中", "に中", "ニジュウ", "にじゅう", "ﾆｼﾞｭｳ", "にじゅ", "二豎",
            "二次", "2次", "虹", "2時", "にじ", "二時", "二字", "尼寺", "ニ次", "🌈",
            "ニジ", "🕑", "躪", "霓", "に", "二", "似", "煮", "仁", "ニ",
            "丹", "尼", "2", "荷", "ⅱ", "弐", "肖", "ニ゙", "②", "に゙",
            "に゚", "ニ゚", "珥", "貮", "怩", "新", "児", "尓", "迩", "爾",
            "姫", "貳", "西", "迯", "逃", "邇", "膩", "轜", "弍", "兒",
            "日"
        ],
        committedCandidate: "²⁰",
        expectedComposingTextAfterCommit: "")
}
