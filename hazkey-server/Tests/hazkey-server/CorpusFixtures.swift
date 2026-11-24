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
            "日本", "2本", "二本", "ニホン", "に本", "にほん", "二ホン", "ニ本", "仁本", "仁保ん",
            "ﾆﾎﾝ", "仁保", "二歩", "にほ", "に", "二", "似", "煮", "仁", "ニ",
            "丹", "尼", "荷", "2", "ⅱ", "弐", "肖", "烹", "ニ゚", "②",
            "に゙", "に゚", "ニ゙", "新", "迯", "姫", "兒", "西", "轜", "貳",
            "日", "逃", "珥", "邇", "膩", "爾", "迩", "怩", "児", "尓",
            "貮", "弍"
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
            "日本", "2本", "二本", "ニホン", "に本", "にほん", "二ホン", "ニ本", "仁本", "仁保ん",
            "ﾆﾎﾝ", "仁保", "二歩", "にほ", "に", "二", "似", "煮", "仁", "ニ",
            "丹", "尼", "荷", "2", "ⅱ", "弐", "肖", "烹", "ニ゚", "②",
            "に゙", "に゚", "ニ゙", "新", "迯", "姫", "兒", "西", "轜", "貳",
            "日", "逃", "珥", "邇", "膩", "爾", "迩", "怩", "児", "尓",
            "貮", "弍"
        ],
        committedCandidate: nil,
        expectedComposingTextAfterCommit: nil)

    static let kanaNumber = CorpusFixture(
        name: "kana-number",
        reading: "にじゅう",
        request: .full(),
        expectedCandidates: [
            "二重", "廿", "二十", "20", "₂₀", "²⁰", "⑳", "⒇", "⒛", "に重",
            "二獣", "二中", "二じゅう", "ニ獣", "に中", "ニジュウ", "にじゅう", "ﾆｼﾞｭｳ", "にじゅ", "二豎",
            "二次", "2次", "虹", "2時", "にじ", "二時", "二字", "尼寺", "ニ次", "🌈",
            "ニジ", "躙", "躪", "🕑", "霓", "に", "二", "似", "煮", "仁",
            "ニ", "丹", "尼", "荷", "2", "ⅱ", "弐", "肖", "烹", "ニ゚",
            "②", "に゙", "に゚", "ニ゙", "新", "迯", "姫", "兒", "西", "轜",
            "貳", "日", "逃", "珥", "邇", "膩", "爾", "迩", "怩", "児",
            "尓", "貮", "弍"
        ],
        committedCandidate: nil,
        expectedComposingTextAfterCommit: nil)

    static let relativeDate = CorpusFixture(
        name: "relative-date",
        reading: "きょう",
        request: .full(numCandidatesPerPage: 1, dateCandidatesAt: 1),
        expectedCandidates: [
            "今日", "きょう", "境", "教", "橋", "京", "卿", "経", "興", "巨",
            "強", "恭", "鏡", "共", "協", "狂", "供", "姜", "響", "キョウ",
            "匡", "夾", "凶", "杏", "香", "峡", "饗", "挟", "ｷｮｳ", "狭",
            "龔", "況", "喬", "羌", "俠", "怯", "僑", "峽", "景", "矯",
            "哽", "僵", "鄕", "誑", "窖", "鏗", "蛩", "鋏", "繦", "烋",
            "襁", "韮", "梟", "鵁", "驕", "秬", "逕", "峺", "摎", "脅",
            "脇", "暁", "亰", "礦", "刧", "竟", "嚮", "匈", "挾", "剄",
            "抂", "薑", "鞏", "磽", "皀", "恊", "兇", "蛬", "恟", "袷",
            "冏", "轎", "篋", "疆", "竸", "享", "筺", "呷", "慊", "徼",
            "胸", "矜", "皎", "驚", "叫", "侠", "經", "况", "澆", "夐",
            "烱", "羮", "亨", "竅", "陜", "餃", "敬", "彊", "磬", "跫",
            "梗", "競", "莢", "恐", "驍", "蕎", "郷", "嬌", "曉", "畊",
            "兢", "狹", "筴", "洶", "兄", "居", "虚", "挙", "許", "キョ",
            "莒", "渠", "炬", "距", "舉", "拠", "擧", "遽", "去", "醵",
            "虛", "鋸", "裾", "據", "拒", "踞", "墟", "圭", "倨", "歔",
            "き", "来", "気", "機", "期", "着", "器", "切", "騎", "記",
            "稀", "木", "キ", "貴", "斬", "基", "樹", "季", "旗", "希",
            "忌", "黄", "帰", "伐", "規", "奇", "喜", "城", "軌", "几",
            "既", "岐", "葱", "癸", "生", "鬼", "斫", "祺", "危", "姫",
            "郗", "衣", "紀", "鑽", "剪", "著", "起", "氣", "柝", "揆",
            "汽", "驥", "桅", "圻", "簋", "綺", "伎", "畿", "き゚", "キ゚",
            "羈", "燹", "覊", "鐫", "黃", "鑚", "水", "諱", "煕", "悸",
            "騏", "崎", "饋", "刄", "机", "刋", "瞶", "畸", "逵", "燬",
            "竒", "次", "甲", "熈", "熙", "聽", "榿", "桔", "槎", "利",
            "曁", "熹", "毅", "嘉", "祈", "嬉", "杵", "屓", "輝", "己",
            "消", "棊", "馗", "來", "簣", "譏", "亜", "聞", "弃", "决",
            "冀", "鎮", "跪", "籏", "晞", "淇", "聆", "饑", "窺", "亀",
            "棋", "咥", "飢", "明", "蛎", "亟", "置", "虧", "唏", "其",
            "杞", "愧", "龜", "箕", "欷", "暉", "徽", "蠣", "耆", "効",
            "哉", "羇", "憙", "公", "豈", "揮", "掎", "詭", "覬", "噐",
            "矩", "稘", "敷", "寄", "餽", "吉", "夬", "朞", "喟", "北",
            "剞", "跂", "效", "亞", "歸", "禧", "皈", "藝", "麒", "曦",
            "妃", "毀", "善", "卉", "僖", "沂", "決", "棄", "聴", "匱",
            "麾", "智", "企", "枳", "幾"
        ],
        committedCandidate: nil,
        expectedComposingTextAfterCommit: nil)

    static let nonLearnableCommit = CorpusFixture(
        name: "non-learnable-kana-number-commit",
        reading: "にじゅう",
        request: .full(),
        expectedCandidates: [
            "二重", "廿", "二十", "20", "₂₀", "²⁰", "⑳", "⒇", "⒛", "に重",
            "二獣", "二中", "二じゅう", "ニ獣", "に中", "ニジュウ", "にじゅう", "ﾆｼﾞｭｳ", "にじゅ", "二豎",
            "二次", "2次", "虹", "2時", "にじ", "二時", "二字", "尼寺", "ニ次", "🌈",
            "ニジ", "躙", "躪", "🕑", "霓", "に", "二", "似", "煮", "仁",
            "ニ", "丹", "尼", "荷", "2", "ⅱ", "弐", "肖", "烹", "ニ゚",
            "②", "に゙", "に゚", "ニ゙", "新", "迯", "姫", "兒", "西", "轜",
            "貳", "日", "逃", "珥", "邇", "膩", "爾", "迩", "怩", "児",
            "尓", "貮", "弍"
        ],
        committedCandidate: "²⁰",
        expectedComposingTextAfterCommit: "")
}
