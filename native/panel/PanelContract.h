#pragma once
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <string>

namespace aes::panel {
inline constexpr wchar_t kControllerName[] = L"PanelController.exe";
inline constexpr wchar_t kHookName[] = L"PanelHook.dll";
inline constexpr DWORD kStateMagic = 0x50414553;
inline constexpr DWORD kStateSchema = 1;
// Cross-process wire format: fixed-width fields, no pointers or C++ objects.
struct RuntimeState {
    DWORD magic = kStateMagic;
    DWORD schema = kStateSchema;
    volatile LONG phase = 0; // idle, starting, active, failed
    volatile LONG lastError = 0;
    volatile LONG categoryChanges = 0;
    volatile LONG itemChanges = 0;
    volatile LONG searchChanges = 0;
    volatile LONG rejectedShapes = 0;
};
static_assert(sizeof(RuntimeState) == 32);
std::wstring WindowsRoot();
std::wstring TargetHostPath();
std::wstring SuggestionModulePath();
std::wstring FileSha256(const std::wstring& path);
bool CheckCompatibility(std::wstring& reason);
}
