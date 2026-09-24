#pragma once
#include "PanelContract.h"
#include "data/Emoji17Catalog.h"
#include <cwctype>
#include <vector>

namespace aes::panel {
inline std::wstring FromUtf8(const char* value) {
    if (!value || !*value) return {};
    int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, -1, nullptr, 0);
    if (length < 2) return {};
    std::wstring result(static_cast<size_t>(length), L'\0');
    if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, -1, result.data(), length)) return {};
    result.resize(static_cast<size_t>(length - 1));
    return result;
}
inline std::wstring Fold(const std::wstring& value) {
    if (value.empty()) return {};
    int length = LCMapStringEx(LOCALE_NAME_INVARIANT, LCMAP_LOWERCASE, value.data(),
                             static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr, 0);
    if (!length) return value;
    std::wstring result(static_cast<size_t>(length), L'\0');
    if (!LCMapStringEx(LOCALE_NAME_INVARIANT, LCMAP_LOWERCASE, value.data(), static_cast<int>(value.size()),
                      result.data(), length, nullptr, nullptr, 0)) return value;
    return result;
}
inline std::vector<const Emoji17Entry*> MatchCatalog(const std::wstring& query) {
    std::vector<std::wstring> terms;
    std::wstring word;
    for (wchar_t c : Fold(query)) {
        if (iswspace(c) || c == L',') { if (!word.empty()) { terms.push_back(word); word.clear(); } }
        else word += c;
    }
    if (!word.empty()) terms.push_back(word);
    std::vector<const Emoji17Entry*> result;
    for (const auto& entry : kEmoji17Entries) {
        const auto haystack = Fold(FromUtf8(entry.name_en) + L" " + FromUtf8(entry.name_zh) + L" " +
                                  FromUtf8(entry.keywords_en) + L" " + FromUtf8(entry.keywords_zh) + L" " +
                                  FromUtf8(entry.sequence_utf8));
        bool match = true;
        for (const auto& term : terms) if (haystack.find(term) == std::wstring::npos) { match = false; break; }
        if (match) result.push_back(&entry);
    }
    return result;
}
}
