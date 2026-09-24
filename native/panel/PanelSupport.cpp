#include "PanelContract.h"
#include <bcrypt.h>
#include <array>
#include <vector>
#pragma comment(lib, "bcrypt.lib")
#pragma comment(lib, "advapi32.lib")

namespace aes::panel {
std::wstring WindowsRoot() {
    wchar_t path[32768]{};
    UINT count = GetWindowsDirectoryW(path, ARRAYSIZE(path));
    return count && count < ARRAYSIZE(path) ? std::wstring(path, count) : L"";
}
static std::wstring InputRoot() {
    auto root = WindowsRoot();
    return root.empty() ? L"" : root + L"\\SystemApps\\MicrosoftWindows.Client.CBS_cw5n1h2txyewy";
}
std::wstring TargetHostPath() { return InputRoot() + L"\\TextInputHost.exe"; }
std::wstring SuggestionModulePath() {
    return InputRoot() + L"\\WindowsInternal.ComposableShell.Experiences.SuggestionUIUndocked.dll";
}
std::wstring FileSha256(const std::wstring& path) {
    HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_DELETE,
                              nullptr, OPEN_EXISTING, FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
    if (file == INVALID_HANDLE_VALUE) return {};
    BCRYPT_ALG_HANDLE algorithm = nullptr;
    BCRYPT_HASH_HANDLE hash = nullptr;
    std::array<unsigned char, 32> digest{};
    std::array<unsigned char, 65536> buffer{};
    bool okay = BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) >= 0;
    if (okay) okay = BCryptCreateHash(algorithm, &hash, nullptr, 0, nullptr, 0, 0) >= 0;
    while (okay) {
        DWORD read = 0;
        if (!ReadFile(file, buffer.data(), static_cast<DWORD>(buffer.size()), &read, nullptr)) { okay = false; break; }
        if (!read) break;
        okay = BCryptHashData(hash, buffer.data(), read, 0) >= 0;
    }
    if (okay) okay = BCryptFinishHash(hash, digest.data(), static_cast<ULONG>(digest.size()), 0) >= 0;
    if (hash) BCryptDestroyHash(hash);
    if (algorithm) BCryptCloseAlgorithmProvider(algorithm, 0);
    CloseHandle(file);
    if (!okay) return {};
    std::wstring result;
    for (auto byte : digest) { result += L"0123456789abcdef"[byte >> 4]; result += L"0123456789abcdef"[byte & 15]; }
    return result;
}
bool CheckCompatibility(std::wstring& reason) {
#ifndef _WIN64
    reason = L"仅支持 Windows x64。"; return false;
#endif
    HKEY key = nullptr;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion",
                     0, KEY_READ | KEY_WOW64_64KEY, &key) != ERROR_SUCCESS) {
        reason = L"无法读取 Windows 版本。"; return false;
    }
    wchar_t build[64]{}; DWORD bytes = sizeof(build), ubr = 0, ubrSize = sizeof(ubr);
    auto result = RegGetValueW(key, nullptr, L"CurrentBuild", RRF_RT_REG_SZ, nullptr, build, &bytes);
    auto ubrResult = RegGetValueW(key, nullptr, L"UBR", RRF_RT_REG_DWORD, nullptr, &ubr, &ubrSize);
    RegCloseKey(key);
    if (result != ERROR_SUCCESS || ubrResult != ERROR_SUCCESS || std::wstring(build) != L"22631" || ubr != 6199) {
        reason = L"此预览仅适配 Windows 11 23H2 22631.6199；检测到系统版本变化，已停止加载。"; return false;
    }
    struct Pin { std::wstring path; const wchar_t* hash; };
    const Pin pins[] = {
        {TargetHostPath(), L"86c14bd4d75cf7130e89a9b91e04c63577637c25db661981cebd9d13741ff955"},
        {InputRoot() + L"\\TextInput.dll", L"5121e295fd7a267849a5d636ed63a718318ec8f01c0575fa14d9e8b906395d77"},
        {SuggestionModulePath(), L"d9d5cd9605d38a45ab8fcd256a65068b530215eb4924fac11cd709377e108c42"},
        {WindowsRoot() + L"\\System32\\AdvancedEmojiDS.dll", L"84430e79468cd93cbd36062a75b1352b8ecc07ceb24f2f9f4518794cca0948cb"},
    };
    for (const auto& pin : pins) {
        if (FileSha256(pin.path) != pin.hash) {
            reason = L"组件版本或 SHA-256 不匹配，已停止加载：" + pin.path; return false;
        }
    }
    reason = L"匹配固定组件；原生面板显示、搜索和输入仍待人工验收。";
    return true;
}
}
