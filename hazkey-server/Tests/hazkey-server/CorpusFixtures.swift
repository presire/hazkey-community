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
            "日本", "2本", "ニホン", "二本", "に本", "にほん", "二ホン", "ニ本", "仁本", "仁保ん",
            "ﾆﾎﾝ", "仁保", "二歩", "にほ", "に", "二", "似", "煮", "仁", "ニ", "丹", "尼", "荷", "2",
            "ⅱ", "弐", "肖", "に゙", "ニ゙", "に゚", "ニ゚", "膩", "兒", "貳", "迯", "日", "怩", "珥",
            "迩", "邇", "逃", "西", "姫", "弍", "尓", "轜", "新", "貮", "児", "爾",
        ],
        committedCandidate: nil,
        expectedComposingTextAfterCommit: nil)

    static let suggestion = CorpusFixture(
        name: "suggestion",
        reading: "にほん",
        request: .suggestion,
        expectedCandidates: ["日本語", "日本史", "日本画"],
        committedCandidate: nil,
        expectedComposingTextAfterCommit: nil)

    static let prefixConversion = CorpusFixture(
        name: "prefix-conversion",
        reading: "にほんご",
        request: .prefix(cursorOffset: -1),
        expectedCandidates: [
            "日本", "2本", "ニホン", "二本", "に本", "にほん", "二ホン", "ニ本", "仁本", "仁保ん",
            "ﾆﾎﾝ", "仁保", "二歩", "にほ", "に", "二", "似", "煮", "仁", "ニ", "丹", "尼", "荷", "2",
            "ⅱ", "弐", "肖", "に゙", "ニ゙", "に゚", "ニ゚", "膩", "兒", "貳", "迯", "日", "怩", "珥",
            "迩", "邇", "逃", "西", "姫", "弍", "尓", "轜", "新", "貮", "児", "爾",
        ],
        committedCandidate: nil,
        expectedComposingTextAfterCommit: nil)

    static let kanaNumber = CorpusFixture(
        name: "kana-number",
        reading: "にじゅう",
        request: .full(),
        expectedCandidates: [
            "二重", "廿", "二十", "20", "₂₀", "²⁰", "⑳", "⒇", "⒛", "に重", "二獣", "ニ獣", "二じゅう",
            "二中", "に中", "ニジュウ", "にじゅう", "ﾆｼﾞｭｳ", "にじゅ", "二豎", "二次", "2次", "虹", "2時",
            "にじ", "二字", "二時", "尼寺", "ニ次", "🌈", "ニジ", "🕑", "霓", "躪", "に", "二", "似", "煮",
            "仁", "ニ", "丹", "尼", "荷", "2", "ⅱ", "弐", "肖", "に゙", "ニ゙", "に゚", "ニ゚", "膩", "兒",
            "貳", "迯", "日", "怩", "珥", "迩", "邇", "逃", "西", "姫", "弍", "尓", "轜", "新", "貮", "児", "爾",
        ],
        committedCandidate: nil,
        expectedComposingTextAfterCommit: nil)

    static let relativeDate = CorpusFixture(
        name: "relative-date",
        reading: "きょう",
        request: .full(numCandidatesPerPage: 1, dateCandidatesAt: 1),
        expectedCandidates: [
            "今日", "きょう", "境", "教", "橋", "京", "卿", "経", "興", "巨", "強", "恭", "鏡", "協", "共", "狂", "姜", "供", "響", "キョウ", "匡", "夾", "凶", "杏", "香", "峡", "饗", "挟", "ｷｮｳ", "狭", "龔", "況", "喬", "羌", "僑", "俠", "怯", "峽", "景", "呷", "兄", "脅", "竸", "刧", "鵁", "驍", "剄", "竅", "繦", "羮", "摎", "誑", "疆", "磬", "彊", "洶", "挾", "跫", "匈", "秬", "恊", "皎", "畊", "餃", "夐", "峺", "皀", "哽", "經", "慊", "磽", "逕", "鄕", "襁", "徼", "抂", "筴", "篋", "矜", "窖", "敬", "冏", "恟", "驚", "筺", "况", "礦", "狹", "蛩", "曉", "暁", "蕎", "轎", "享", "兇", "脇", "梗", "烋", "侠", "亨", "鋏", "澆", "袷", "叫", "矯", "胸", "嚮", "驕", "鏗", "烱", "嬌", "鞏", "蛬", "郷", "兢", "莢", "陜", "亰", "薑", "僵", "竟", "韮", "競", "恐", "梟", "居", "虚", "挙", "許", "キョ", "莒", "渠", "炬", "距", "遽", "倨", "去", "醵", "墟", "圭", "歔", "擧", "虛", "踞", "鋸", "據", "舉", "裾", "拒", "拠", "き", "来", "気", "機", "期", "着", "切", "器", "騎", "記", "稀", "木", "キ", "斬", "貴", "基", "樹", "季", "旗", "希", "黄", "帰", "忌", "伐", "規", "奇", "喜", "城", "軌", "既", "岐", "几", "葱", "癸", "鬼", "斫", "生", "祺", "郗", "姫", "危", "紀", "氣", "起", "汽", "揆", "綺", "簋", "驥", "柝", "圻", "桅", "伎", "畿", "キ゚", "き゚", "箕", "智", "曁", "熹", "效", "公", "覬", "淇", "善", "置", "覊", "煕", "揮", "藝", "棊", "畸", "饑", "鎮", "徽", "次", "匱", "明", "輝", "嬉", "掎", "棋", "憙", "蛎", "諱", "暉", "龜", "毅", "聴", "悸", "麒", "槎", "哉", "稘", "跪", "朞", "聽", "榿", "枳", "桔", "燹", "刄", "愧", "寄", "逵", "嘉", "弃", "黃", "饋", "燬", "唏", "簣", "羈", "水", "妃", "馗", "亞", "毀", "瞶", "屓", "餽", "跂", "熙", "北", "飢", "決", "祈", "熈", "豈", "甲", "亟", "蠣", "鑚", "籏", "鐫", "棄", "亀", "噐", "沂", "吉", "窺", "剞", "企", "耆", "崎", "机", "曦", "皈", "歸", "卉", "己", "譏", "矩", "咥", "衣", "聆", "敷", "决", "竒", "冀", "僖", "刋", "杞", "麾", "其", "幾", "騏", "羇", "夬", "禧", "聞", "欷", "利", "來", "亜", "詭", "消", "晞", "喟", "杵", "虧", "効",
        ],
        committedCandidate: nil,
        expectedComposingTextAfterCommit: nil)

    static let nonLearnableCommit = CorpusFixture(
        name: "non-learnable-kana-number-commit",
        reading: "にじゅう",
        request: .full(),
        expectedCandidates: [
            "二重", "廿", "二十", "20", "₂₀", "²⁰", "⑳", "⒇", "⒛", "に重", "二獣", "ニ獣", "二じゅう",
            "二中", "に中", "ニジュウ", "にじゅう", "ﾆｼﾞｭｳ", "にじゅ", "二豎", "二次", "2次", "虹", "2時",
            "にじ", "二字", "二時", "尼寺", "ニ次", "🌈", "ニジ", "🕑", "霓", "躪", "に", "二", "似", "煮",
            "仁", "ニ", "丹", "尼", "荷", "2", "ⅱ", "弐", "肖", "に゙", "ニ゙", "に゚", "ニ゚", "膩", "兒",
            "貳", "迯", "日", "怩", "珥", "迩", "邇", "逃", "西", "姫", "弍", "尓", "轜", "新", "貮", "児", "爾",
        ],
        committedCandidate: "²⁰",
        expectedComposingTextAfterCommit: "")
}
