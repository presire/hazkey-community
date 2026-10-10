#include "hazkey_utf8.h"
#include <cstddef>
#include <iostream>
#include <string>
#include <string_view>

namespace {

int failures = 0;

void expectOutput(std::string_view label, std::string_view input,
                  std::string_view expected) {
    const std::string actual = hazkey::frontend::makeValidUtf8(input);
    if (actual != expected) {
        std::cerr << "FAIL [" << label << "] output differed from expected\n";
        ++failures;
    }
}

std::string replacementBytes(std::size_t count) {
    std::string output;
    for (std::size_t index = 0; index < count; ++index) {
        output.append("\xEF\xBF\xBD");
    }
    return output;
}

void testValidUtf8IsUnchanged() {
    expectOutput("ASCII", "Hazkey community", "Hazkey community");
    expectOutput("Japanese", "かな漢字", "かな漢字");
    expectOutput("emoji ZWJ", "👩‍💻", "👩‍💻");
}

void testInvalidBytesAreReplacedOneAtATime() {
    expectOutput("NUL", std::string("a\0b", 3),
                 std::string("a") + replacementBytes(1) + "b");
    expectOutput("lone continuation", std::string(1, static_cast<char>(0x80)),
                 replacementBytes(1));
    expectOutput("0xFF", std::string(1, static_cast<char>(0xFF)),
                 replacementBytes(1));
    expectOutput("overlong", std::string("\xC0\xAF", 2), replacementBytes(2));
    expectOutput("surrogate", std::string("\xED\xA0\x80", 3),
                 replacementBytes(3));
    expectOutput("above U+10FFFF", std::string("\xF4\x90\x80\x80", 4),
                 replacementBytes(4));
    expectOutput("truncated at end", std::string("\xE3\x81", 2),
                 replacementBytes(2));
    expectOutput("mixed valid and invalid",
                 std::string("A\x80", 2) + "日" + std::string("\xFF", 1) + "Z",
                 std::string("A") + replacementBytes(1) + "日" +
                     replacementBytes(1) + "Z");
}

void testRepairIsIdempotent() {
    const std::string invalid =
        std::string("A\xED\xA0\x80", 4) + "日本" + std::string("\xE3\x81", 2);
    const std::string repaired = hazkey::frontend::makeValidUtf8(invalid);
    expectOutput("idempotency", repaired, repaired);
}

}

int main() {
    testValidUtf8IsUnchanged();
    testInvalidBytesAreReplacedOneAtATime();
    testRepairIsIdempotent();
    if (failures > 0) {
        std::cerr << "hazkey_utf8_test: " << failures << " failures\n";
        return 1;
    }
    std::cout << "hazkey_utf8_test: OK\n";
    return 0;
}
