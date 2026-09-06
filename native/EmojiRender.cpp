// EmojiRender.cpp
// Private DirectWrite/Direct2D color-emoji rasterizer for AppleEmojiSwitcher.
// It deliberately builds a collection from exactly one local font file and
// installs an empty DirectWrite fallback object. A request that produces .notdef
// or an uninked bitmap is an error; no system font is used as a substitute.

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <d2d1_3.h>
#include <d3d11_4.h>
#include <dwrite_3.h>
#include <dxgi1_2.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <memory>
#include <regex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

using Microsoft::WRL::ComPtr;
namespace fs = std::filesystem;

namespace {

struct Failure final : std::runtime_error {
    explicit Failure(const std::string& message) : std::runtime_error(message) {}
};

std::string Utf8(const std::wstring& text) {
    if (text.empty()) return {};
    const int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(),
                                         static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
    if (size <= 0) throw Failure("UTF-16 to UTF-8 conversion failed");
    std::string out(static_cast<size_t>(size), '\0');
    if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()),
                            out.data(), size, nullptr, nullptr) != size) {
        throw Failure("UTF-16 to UTF-8 conversion failed");
    }
    return out;
}

std::wstring Wide(const std::string& text) {
    if (text.empty()) return {};
    const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
                                         static_cast<int>(text.size()), nullptr, 0);
    if (size <= 0) throw Failure("UTF-8 input is invalid");
    std::wstring out(static_cast<size_t>(size), L'\0');
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()),
                            out.data(), size) != size) {
        throw Failure("UTF-8 input is invalid");
    }
    return out;
}

std::string HrText(HRESULT hr) {
    wchar_t* system = nullptr;
    const DWORD len = FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
                                         FORMAT_MESSAGE_IGNORE_INSERTS,
                                     nullptr, static_cast<DWORD>(hr), 0,
                                     reinterpret_cast<wchar_t*>(&system), 0, nullptr);
    std::ostringstream out;
    out << "HRESULT 0x" << std::uppercase << std::hex << static_cast<unsigned long>(hr);
    if (len != 0 && system != nullptr) {
        std::wstring message(system, len);
        LocalFree(system);
        while (!message.empty() && (message.back() == L'\r' || message.back() == L'\n')) message.pop_back();
        out << ": " << Utf8(message);
    }
    return out.str();
}

void Check(HRESULT hr, const char* action) {
    if (FAILED(hr)) throw Failure(std::string(action) + ": " + HrText(hr));
}

std::string Json(const std::string& value) {
    std::ostringstream out;
    out << '"';
    for (unsigned char c : value) {
        switch (c) {
            case '"': out << "\\\""; break;
            case '\\': out << "\\\\"; break;
            case '\b': out << "\\b"; break;
            case '\f': out << "\\f"; break;
            case '\n': out << "\\n"; break;
            case '\r': out << "\\r"; break;
            case '\t': out << "\\t"; break;
            default:
                if (c < 0x20) {
                    out << "\\u" << std::hex << std::setw(4) << std::setfill('0') << static_cast<int>(c)
                        << std::dec << std::setfill(' ');
                } else {
                    out << static_cast<char>(c);
                }
        }
    }
    out << '"';
    return out.str();
}

std::string JsonW(const std::wstring& value) { return Json(Utf8(value)); }

std::wstring AbsolutePath(const fs::path& path) {
    std::error_code ec;
    const fs::path absolute = fs::absolute(path, ec);
    if (ec) throw Failure("Cannot resolve path: " + path.string());
    return absolute.wstring();
}

struct Request {
    std::string id;
    std::vector<uint32_t> codepoints;
    std::wstring text;
    std::string normalizedCodepoints;
};

std::wstring EncodeCodepoints(const std::vector<uint32_t>& codepoints) {
    std::wstring text;
    for (const uint32_t cp : codepoints) {
        if (cp <= 0xFFFF) {
            text.push_back(static_cast<wchar_t>(cp));
        } else {
            const uint32_t shifted = cp - 0x10000;
            text.push_back(static_cast<wchar_t>(0xD800 + (shifted >> 10)));
            text.push_back(static_cast<wchar_t>(0xDC00 + (shifted & 0x3FF)));
        }
    }
    return text;
}

std::string NormalizedCodepoints(const std::vector<uint32_t>& codepoints) {
    std::ostringstream out;
    for (size_t i = 0; i < codepoints.size(); ++i) {
        if (i != 0) out << ' ';
        out << std::uppercase << std::hex << codepoints[i] << std::dec;
    }
    return out.str();
}

std::vector<Request> ReadRequests(const fs::path& file) {
    std::ifstream input(file, std::ios::binary);
    if (!input) throw Failure("Cannot open requests TSV: " + file.string());
    std::vector<Request> requests;
    const std::regex idPattern("^[A-Za-z0-9_]+$");
    std::string line;
    size_t lineNumber = 0;
    while (std::getline(input, line)) {
        ++lineNumber;
        if (lineNumber == 1 && line.size() >= 3 && static_cast<unsigned char>(line[0]) == 0xEF &&
            static_cast<unsigned char>(line[1]) == 0xBB && static_cast<unsigned char>(line[2]) == 0xBF) {
            line.erase(0, 3);
        }
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.empty()) continue;
        const size_t tab = line.find('\t');
        if (tab == std::string::npos || line.find('\t', tab + 1) != std::string::npos) {
            throw Failure("Requests TSV line " + std::to_string(lineNumber) + " must contain exactly one tab");
        }
        Request request;
        request.id = line.substr(0, tab);
        if (!std::regex_match(request.id, idPattern)) {
            throw Failure("Unsafe request id on TSV line " + std::to_string(lineNumber));
        }
        std::istringstream values(line.substr(tab + 1));
        std::string token;
        while (values >> token) {
            size_t used = 0;
            uint32_t cp = 0;
            try {
                const unsigned long parsed = std::stoul(token, &used, 16);
                if (used != token.size() || parsed > 0x10FFFFUL) throw std::invalid_argument("bad code point");
                cp = static_cast<uint32_t>(parsed);
            } catch (const std::exception&) {
                throw Failure("Invalid hexadecimal code point on TSV line " + std::to_string(lineNumber));
            }
            if (cp >= 0xD800 && cp <= 0xDFFF) {
                throw Failure("Surrogate code point is not valid input on TSV line " + std::to_string(lineNumber));
            }
            request.codepoints.push_back(cp);
        }
        if (request.codepoints.empty()) throw Failure("Empty code point list on TSV line " + std::to_string(lineNumber));
        request.text = EncodeCodepoints(request.codepoints);
        request.normalizedCodepoints = NormalizedCodepoints(request.codepoints);
        requests.push_back(std::move(request));
    }
    if (requests.empty()) throw Failure("Requests TSV contains no requests");
    return requests;
}

std::vector<float> ParseSizes(const std::wstring& value) {
    std::vector<float> sizes;
    std::wstringstream input(value);
    std::wstring token;
    while (std::getline(input, token, L',')) {
        if (token.empty()) throw Failure("Empty --sizes component");
        size_t used = 0;
        float size = 0.0f;
        try {
            size = std::stof(token, &used);
        } catch (const std::exception&) {
            throw Failure("Invalid --sizes component");
        }
        if (used != token.size() || !std::isfinite(size) || size <= 0.0f || size > 512.0f) {
            throw Failure("Invalid --sizes component");
        }
        sizes.push_back(size);
    }
    if (sizes.empty()) throw Failure("--sizes is empty");
    return sizes;
}

struct Options {
    std::wstring font;
    fs::path requests;
    fs::path out;
    std::vector<float> sizes;
    bool diagnose = false;
};

Options ParseOptions(int argc, wchar_t** argv) {
    Options options;
    for (int i = 1; i < argc; ++i) {
        const std::wstring arg = argv[i];
        if ((arg == L"--font" || arg == L"--requests" || arg == L"--out" || arg == L"--sizes") && i + 1 >= argc) {
            throw Failure("Missing value for " + Utf8(arg));
        }
        if (arg == L"--font") options.font = argv[++i];
        else if (arg == L"--requests") options.requests = argv[++i];
        else if (arg == L"--out") options.out = argv[++i];
        else if (arg == L"--sizes") options.sizes = ParseSizes(argv[++i]);
        else if (arg == L"--diagnose") options.diagnose = true;
        else if (arg == L"--help" || arg == L"-h") {
            std::wcout << L"EmojiRender.exe --font FONT_FILE|@system --requests REQUESTS_TSV --out OUTPUT_DIR "
                          L"--sizes 20,26,32,40,48,52,56,64,72,80,88,96 [--diagnose]\n";
            std::exit(0);
        } else {
            throw Failure("Unknown argument: " + Utf8(arg));
        }
    }
    if (options.font.empty() || options.requests.empty() || options.out.empty() || options.sizes.empty()) {
        throw Failure("--font, --requests, --out, and --sizes are required");
    }
    if (options.font != L"@system" && !fs::is_regular_file(options.font)) {
        throw Failure("Font file does not exist: " + Utf8(options.font));
    }
    if (!fs::is_regular_file(options.requests)) throw Failure("Requests TSV does not exist");
    return options;
}

std::wstring LocalizedString(IDWriteLocalizedStrings* strings) {
    UINT32 index = 0;
    BOOL exists = FALSE;
    if (FAILED(strings->FindLocaleName(L"en-us", &index, &exists)) || !exists) index = 0;
    UINT32 length = 0;
    Check(strings->GetStringLength(index, &length), "Read localized string length");
    std::wstring value(static_cast<size_t>(length) + 1, L'\0');
    Check(strings->GetString(index, value.data(), length + 1), "Read localized string");
    value.resize(length);
    return value;
}

std::wstring FacePath(IDWriteFontFace* face) {
    UINT32 count = 0;
    Check(face->GetFiles(&count, nullptr), "Get font face file count");
    if (count != 1) throw Failure("Requested font face does not resolve to exactly one font file");
    std::vector<ComPtr<IDWriteFontFile>> files(count);
    std::vector<IDWriteFontFile*> raw(count);
    for (size_t i = 0; i < files.size(); ++i) raw[i] = files[i].Get();
    // GetFiles creates references through raw out pointers, not preallocated ComPtrs.
    raw.assign(count, nullptr);
    Check(face->GetFiles(&count, raw.data()), "Get font face file");
    files[0].Attach(raw[0]);
    ComPtr<IDWriteFontFileLoader> loader;
    Check(files[0]->GetLoader(&loader), "Get font file loader");
    ComPtr<IDWriteLocalFontFileLoader> localLoader;
    Check(loader.As(&localLoader), "Requested face is not backed by a local font file");
    const void* key = nullptr;
    UINT32 keySize = 0;
    Check(files[0]->GetReferenceKey(&key, &keySize), "Get font file reference key");
    UINT32 needed = 0;
    Check(localLoader->GetFilePathLengthFromKey(key, keySize, &needed), "Get font file path length");
    std::wstring path(static_cast<size_t>(needed) + 1, L'\0');
    Check(localLoader->GetFilePathFromKey(key, keySize, path.data(), needed + 1), "Get font file path");
    path.resize(needed);
    return path;
}

struct Shaped {
    std::vector<UINT16> glyphs;
    std::vector<float> advances;
    std::vector<DWRITE_GLYPH_OFFSET> offsets;
    std::vector<DWRITE_GLYPH_IMAGE_FORMATS> formats;
};

// IDWriteTextLayout::Draw exposes the glyph runs that the layout will submit
// before Direct2D expands COLR/CBDT color layers. The manifest must describe
// those runs, rather than an independently configured TextAnalyzer call.
class GlyphRunCapture final : public IDWriteTextRenderer {
public:
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** object) override {
        if (object == nullptr) return E_INVALIDARG;
        *object = nullptr;
        if (iid == __uuidof(IUnknown) || iid == __uuidof(IDWritePixelSnapping) ||
            iid == __uuidof(IDWriteTextRenderer)) {
            *object = static_cast<IDWriteTextRenderer*>(this);
            AddRef();
            return S_OK;
        }
        return E_NOINTERFACE;
    }

    ULONG STDMETHODCALLTYPE AddRef() override { return static_cast<ULONG>(InterlockedIncrement(&references_)); }

    ULONG STDMETHODCALLTYPE Release() override {
        const ULONG remaining = static_cast<ULONG>(InterlockedDecrement(&references_));
        if (remaining == 0) delete this;
        return remaining;
    }

    HRESULT STDMETHODCALLTYPE IsPixelSnappingDisabled(void*, BOOL* disabled) override {
        if (disabled == nullptr) return E_INVALIDARG;
        *disabled = FALSE;
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE GetCurrentTransform(void*, DWRITE_MATRIX* transform) override {
        if (transform == nullptr) return E_INVALIDARG;
        *transform = DWRITE_MATRIX{1.0f, 0.0f, 0.0f, 1.0f, 0.0f, 0.0f};
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE GetPixelsPerDip(void*, FLOAT* pixelsPerDip) override {
        if (pixelsPerDip == nullptr) return E_INVALIDARG;
        *pixelsPerDip = 1.0f;
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE DrawGlyphRun(void*, FLOAT, FLOAT, DWRITE_MEASURING_MODE,
                                            const DWRITE_GLYPH_RUN* run,
                                            const DWRITE_GLYPH_RUN_DESCRIPTION*, IUnknown*) override {
        if (run == nullptr || run->fontFace == nullptr || run->glyphCount == 0 || run->glyphIndices == nullptr ||
            run->glyphAdvances == nullptr) {
            return E_INVALIDARG;
        }
        try {
            if (!face_) {
                face_ = run->fontFace;
            } else if (face_.Get() != run->fontFace) {
                multipleFaces_ = true;
            }
            glyphs_.insert(glyphs_.end(), run->glyphIndices, run->glyphIndices + run->glyphCount);
            advances_.insert(advances_.end(), run->glyphAdvances, run->glyphAdvances + run->glyphCount);
            if (run->glyphOffsets != nullptr) {
                offsets_.insert(offsets_.end(), run->glyphOffsets, run->glyphOffsets + run->glyphCount);
            } else {
                offsets_.insert(offsets_.end(), run->glyphCount, DWRITE_GLYPH_OFFSET{});
            }
            ++runCount_;
            return S_OK;
        } catch (const std::bad_alloc&) {
            return E_OUTOFMEMORY;
        } catch (...) {
            return E_FAIL;
        }
    }

    HRESULT STDMETHODCALLTYPE DrawUnderline(void*, FLOAT, FLOAT, const DWRITE_UNDERLINE*, IUnknown*) override {
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE DrawStrikethrough(void*, FLOAT, FLOAT, const DWRITE_STRIKETHROUGH*, IUnknown*) override {
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE DrawInlineObject(void*, FLOAT, FLOAT, IDWriteInlineObject*, BOOL, BOOL,
                                                IUnknown*) override {
        return S_OK;
    }

    UINT32 runCount() const { return runCount_; }
    bool multipleFaces() const { return multipleFaces_; }
    IDWriteFontFace* face() const { return face_.Get(); }
    const std::vector<UINT16>& glyphs() const { return glyphs_; }
    const std::vector<float>& advances() const { return advances_; }
    const std::vector<DWRITE_GLYPH_OFFSET>& offsets() const { return offsets_; }

private:
    volatile LONG references_ = 1;
    UINT32 runCount_ = 0;
    bool multipleFaces_ = false;
    ComPtr<IDWriteFontFace> face_;
    std::vector<UINT16> glyphs_;
    std::vector<float> advances_;
    std::vector<DWRITE_GLYPH_OFFSET> offsets_;
};

class Renderer {
public:
    explicit Renderer(const Options& options) : options_(options) { Initialize(); }

    std::wstring family() const { return family_; }
    std::wstring matchedPath() const { return matchedPath_; }
    bool customCollection() const { return customCollection_; }

    Shaped Shape(const Request& request, float size) const {
        const UINT32 textLength = static_cast<UINT32>(request.text.size());
        const UINT32 capacity = std::max<UINT32>(64, textLength * 16 + 16);
        std::vector<UINT16> clusterMap(textLength);
        std::vector<DWRITE_SHAPING_TEXT_PROPERTIES> textProperties(textLength);
        std::vector<UINT16> glyphs(capacity);
        std::vector<DWRITE_SHAPING_GLYPH_PROPERTIES> glyphProperties(capacity);
        DWRITE_SCRIPT_ANALYSIS analysis{};
        analysis.script = 0;
        analysis.shapes = DWRITE_SCRIPT_SHAPES_DEFAULT;
        UINT32 actualGlyphs = 0;
        Check(analyzer_->GetGlyphs(request.text.data(), textLength, face_.Get(), FALSE, FALSE, &analysis, L"en-us",
                                   nullptr, nullptr, nullptr, 0, capacity, clusterMap.data(), textProperties.data(),
                                   glyphs.data(), glyphProperties.data(), &actualGlyphs),
              "Shape request without fallback");
        if (actualGlyphs == 0) throw Failure("No glyphs produced for " + request.id);
        glyphs.resize(actualGlyphs);
        glyphProperties.resize(actualGlyphs);
        if (std::find(glyphs.begin(), glyphs.end(), static_cast<UINT16>(0)) != glyphs.end()) {
            throw Failure("Requested font returned .notdef/tofu for " + request.id);
        }
        std::vector<float> advances(actualGlyphs);
        std::vector<DWRITE_GLYPH_OFFSET> offsets(actualGlyphs);
        Check(analyzer_->GetGlyphPlacements(request.text.data(), clusterMap.data(), textProperties.data(), textLength,
                                            glyphs.data(), glyphProperties.data(), actualGlyphs, face_.Get(), size,
                                            FALSE, FALSE, &analysis, L"en-us", nullptr, nullptr, 0, advances.data(),
                                            offsets.data()),
              "Measure shaped request");
        std::vector<DWRITE_GLYPH_IMAGE_FORMATS> imageFormats;
        imageFormats.reserve(glyphs.size());
        const UINT32 ppem = static_cast<UINT32>(std::max(1.0f, std::ceil(size)));
        for (const UINT16 glyph : glyphs) {
            DWRITE_GLYPH_IMAGE_FORMATS glyphFormat = DWRITE_GLYPH_IMAGE_FORMATS_NONE;
            Check(face4_->GetGlyphImageFormats(glyph, ppem, ppem, &glyphFormat), "Inspect glyph image format");
            imageFormats.push_back(glyphFormat);
        }
        return {std::move(glyphs), std::move(advances), std::move(offsets), std::move(imageFormats)};
    }

    struct Image {
        fs::path path;
        UINT32 width = 0;
        UINT32 height = 0;
        float advance = 0.0f;
        float offsetX = 0.0f;
        float offsetY = 0.0f;
        UINT64 inkPixels = 0;
        UINT64 colorPixels = 0;
        std::vector<UINT16> glyphs;
        UINT32 visibleGlyphCount = 0;
    };

    Image Render(const Request& request, float size, const fs::path& imagePath) {
        const Shaped shaped = CaptureLayoutShape(request, size);
        if (options_.diagnose) {
            const Shaped analyzerShape = Shape(request, size);
            PrintShapeDiagnostic("layout", request, size, shaped);
            PrintShapeDiagnostic("analyzer", request, size, analyzerShape);
            if (shaped.glyphs != analyzerShape.glyphs) {
                std::cerr << "EmojiRender diagnose layout-analyzer-mismatch id=" << request.id << "\n";
            }
        }
        const float advance = Sum(shaped.advances);
        DWRITE_FONT_METRICS metrics{};
        face_->GetMetrics(&metrics);
        const float ascent = size * static_cast<float>(metrics.ascent) / static_cast<float>(metrics.designUnitsPerEm);
        const float leftMargin = size * 3.0f + 12.0f;
        const float topMargin = size * 3.0f + 12.0f;
        const float baselineY = topMargin + ascent;
        const UINT32 canvasWidth = static_cast<UINT32>(std::ceil(std::max(size * 8.0f, advance + size * 6.0f + 24.0f)));
        const UINT32 canvasHeight = static_cast<UINT32>(std::ceil(std::max(size * 8.0f, size * 6.0f + 24.0f)));
        EnsureSurface(canvasWidth, canvasHeight);
        context4_->SetTarget(target_.Get());
        context4_->SetTransform(D2D1::Matrix3x2F::Identity());
        context4_->BeginDraw();
        context4_->Clear(D2D1_COLOR_F{0.0f, 0.0f, 0.0f, 0.0f});
        context4_->DrawTextLayout(D2D1::Point2F(leftMargin, topMargin), layout_.Get(), brush_.Get(), nullptr, 0,
                                  D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT);
        Check(context4_->EndDraw(), "Render color glyphs with Direct2D");

        std::vector<uint8_t> pixels = Readback(canvasWidth, canvasHeight);
        const Bounds bounds = FindInkBounds(pixels, canvasWidth, canvasHeight);
        if (!bounds.hasInk) {
            if (options_.diagnose) ProbeOutlineDraw(request, shaped, canvasWidth, canvasHeight, leftMargin, baselineY);
            throw Failure("Direct2D rendered no ink for " + request.id);
        }
        std::vector<uint8_t> crop = Crop(pixels, canvasWidth, bounds);
        fs::create_directories(imagePath.parent_path());
        WritePng(imagePath, crop, bounds.width(), bounds.height());
        Image result;
        result.path = imagePath;
        result.width = bounds.width();
        result.height = bounds.height();
        result.advance = advance;
        result.offsetX = static_cast<float>(bounds.left) - leftMargin;
        result.offsetY = baselineY - static_cast<float>(bounds.top);
        result.inkPixels = bounds.inkPixels;
        result.colorPixels = bounds.colorPixels;
        result.glyphs = shaped.glyphs;
        result.visibleGlyphCount = static_cast<UINT32>(std::count_if(
            shaped.advances.begin(), shaped.advances.end(), [](float advance) { return std::fabs(advance) > 0.01f; }));
        return result;
    }

    void PrepareLayout(const Request& request, float size) {
        layoutFontSize_ = size;
        Check(factory_->CreateTextFormat(family_.c_str(), collection_.Get(), DWRITE_FONT_WEIGHT_NORMAL,
                                         DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, size, L"en-us",
                                         &format_),
              "Create exact-font text format");
        ComPtr<IDWriteTextFormat3> format3;
        Check(format_.As(&format3), "Query IDWriteTextFormat3");
        Check(format3->SetFontFallback(noFallback_.Get()), "Disable font fallback");
        Check(factory_->CreateTextLayout(request.text.data(), static_cast<UINT32>(request.text.size()), format_.Get(),
                                         8192.0f, 8192.0f, &layout_),
              "Create text layout");
    }

private:
    struct Bounds {
        UINT32 left = 0;
        UINT32 top = 0;
        UINT32 right = 0;
        UINT32 bottom = 0;
        UINT64 inkPixels = 0;
        UINT64 colorPixels = 0;
        bool hasInk = false;
        UINT32 width() const { return right - left; }
        UINT32 height() const { return bottom - top; }
    };

    Shaped CaptureLayoutShape(const Request& request, float size) const {
        ComPtr<GlyphRunCapture> capture;
        capture.Attach(new GlyphRunCapture());
        Check(layout_->Draw(nullptr, capture.Get(), 0.0f, 0.0f), "Capture actual text layout glyph runs");
        if (capture->runCount() == 0 || capture->face() == nullptr || capture->glyphs().empty()) {
            throw Failure("Text layout produced no glyph runs for " + request.id);
        }
        if (capture->multipleFaces()) {
            throw Failure("Text layout used multiple font faces for " + request.id);
        }
        const std::wstring layoutFacePath = FacePath(capture->face());
        if (CompareStringOrdinal(matchedPath_.c_str(), -1, layoutFacePath.c_str(), -1, TRUE) != CSTR_EQUAL) {
            throw Failure("Text layout used a font face other than the requested target for " + request.id);
        }
        if (std::find(capture->glyphs().begin(), capture->glyphs().end(), static_cast<UINT16>(0)) !=
            capture->glyphs().end()) {
            throw Failure("Text layout returned .notdef/tofu for " + request.id);
        }
        ComPtr<IDWriteFontFace4> layoutFace4;
        Check(capture->face()->QueryInterface(IID_PPV_ARGS(&layoutFace4)), "Query layout glyph-run font face");
        std::vector<DWRITE_GLYPH_IMAGE_FORMATS> formats;
        formats.reserve(capture->glyphs().size());
        const UINT32 ppem = static_cast<UINT32>(std::max(1.0f, std::ceil(size)));
        for (const UINT16 glyph : capture->glyphs()) {
            DWRITE_GLYPH_IMAGE_FORMATS glyphFormat = DWRITE_GLYPH_IMAGE_FORMATS_NONE;
            Check(layoutFace4->GetGlyphImageFormats(glyph, ppem, ppem, &glyphFormat),
                  "Inspect layout glyph image format");
            formats.push_back(glyphFormat);
        }
        return {capture->glyphs(), capture->advances(), capture->offsets(), std::move(formats)};
    }

    void Initialize() {
        Check(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&wic_)),
              "Create WIC factory");
        Check(DWriteCreateFactory(DWRITE_FACTORY_TYPE_ISOLATED, __uuidof(IDWriteFactory5),
                                  reinterpret_cast<IUnknown**>(factory_.GetAddressOf())),
              "Create DirectWrite factory");
        CreateExactCollection();
        Check(collection_->GetFontFamily(familyIndex_, &fontFamily_), "Get selected font family");
        ComPtr<IDWriteLocalizedStrings> names;
        Check(fontFamily_->GetFamilyNames(&names), "Read font family names");
        family_ = LocalizedString(names.Get());
        Check(fontFamily_->GetFirstMatchingFont(DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STRETCH_NORMAL,
                                                DWRITE_FONT_STYLE_NORMAL, &font_),
              "Get local regular font");
        Check(font_->CreateFontFace(&face_), "Create exact font face");
        Check(face_.As(&face4_), "Query IDWriteFontFace4");
        matchedPath_ = FacePath(face_.Get());
        if (customCollection_) {
            const std::wstring expected = AbsolutePath(options_.font);
            if (CompareStringOrdinal(expected.c_str(), -1, matchedPath_.c_str(), -1, TRUE) != CSTR_EQUAL) {
                throw Failure("Custom DirectWrite collection resolved a different font file");
            }
        }
        Check(factory_->CreateTextAnalyzer(&analyzer_), "Create DirectWrite text analyzer");
        ComPtr<IDWriteFontFallbackBuilder> fallbackBuilder;
        Check(factory_->CreateFontFallbackBuilder(&fallbackBuilder), "Create empty fallback builder");
        Check(fallbackBuilder->CreateFontFallback(&noFallback_), "Create empty fallback object");
        CreateGraphics();
    }

    void CreateExactCollection() {
        if (options_.font == L"@system") {
            customCollection_ = false;
            Check(factory_->GetSystemFontCollection(&collection_, FALSE), "Open system font collection");
            UINT32 index = 0;
            BOOL exists = FALSE;
            Check(collection_->FindFamilyName(L"Segoe UI Emoji", &index, &exists), "Find Segoe UI Emoji");
            if (!exists) throw Failure("System Segoe UI Emoji family is unavailable");
            familyIndex_ = index;
            return;
        }
        customCollection_ = true;
        ComPtr<IDWriteFontSetBuilder1> builder;
        Check(factory_->CreateFontSetBuilder(&builder), "Create private font-set builder");
        const std::wstring localPath = AbsolutePath(options_.font);
        ComPtr<IDWriteFontFile> fontFile;
        Check(factory_->CreateFontFileReference(localPath.c_str(), nullptr, &fontFile), "Create private font file reference");
        Check(builder->AddFontFile(fontFile.Get()), "Add private font file");
        ComPtr<IDWriteFontSet> set;
        Check(builder->CreateFontSet(&set), "Create private font set");
        ComPtr<IDWriteFontCollection1> collection1;
        Check(factory_->CreateFontCollectionFromFontSet(set.Get(), &collection1), "Create private font collection");
        Check(collection1.As(&collection_), "Use private font collection");
    }

    void CreateGraphics() {
        const D3D_FEATURE_LEVEL requested[] = {D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0,
                                                D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_10_0};
        UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
        D3D_FEATURE_LEVEL acquired{};
        HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags, requested,
                                       static_cast<UINT>(std::size(requested)), D3D11_SDK_VERSION, &d3d_, &acquired,
                                       &d3dContext_);
        if (FAILED(hr)) {
            Check(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr, flags, requested,
                                    static_cast<UINT>(std::size(requested)), D3D11_SDK_VERSION, &d3d_, &acquired,
                                    &d3dContext_),
                  "Create Direct3D device (hardware and WARP failed)");
        }
        ComPtr<IDXGIDevice> dxgiDevice;
        Check(d3d_.As(&dxgiDevice), "Query DXGI device");
        Check(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, IID_PPV_ARGS(&d2dFactory_)),
              "Create Direct2D factory");
        Check(d2dFactory_->CreateDevice(dxgiDevice.Get(), &d2dDevice_), "Create Direct2D device");
        ComPtr<ID2D1DeviceContext> baseContext;
        Check(d2dDevice_->CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE, &baseContext),
              "Create Direct2D device context");
        Check(baseContext.As(&context4_), "Query ID2D1DeviceContext4 (color font renderer)");
        Check(context4_->CreateSolidColorBrush(D2D1::ColorF(D2D1::ColorF::Black), &brush_), "Create text brush");
    }

    void EnsureSurface(UINT32 width, UINT32 height) {
        if (surfaceWidth_ == width && surfaceHeight_ == height && texture_) return;
        target_.Reset();
        staging_.Reset();
        texture_.Reset();
        D3D11_TEXTURE2D_DESC desc{};
        desc.Width = width;
        desc.Height = height;
        desc.MipLevels = 1;
        desc.ArraySize = 1;
        desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        desc.SampleDesc.Count = 1;
        desc.Usage = D3D11_USAGE_DEFAULT;
        desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
        Check(d3d_->CreateTexture2D(&desc, nullptr, &texture_), "Create render texture");
        desc.Usage = D3D11_USAGE_STAGING;
        desc.BindFlags = 0;
        desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        Check(d3d_->CreateTexture2D(&desc, nullptr, &staging_), "Create readback texture");
        ComPtr<IDXGISurface> surface;
        Check(texture_.As(&surface), "Query render texture as DXGI surface");
        const D2D1_BITMAP_PROPERTIES1 properties = D2D1::BitmapProperties1(
            D2D1_BITMAP_OPTIONS_TARGET, D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED),
            96.0f, 96.0f);
        Check(context4_->CreateBitmapFromDxgiSurface(surface.Get(), &properties, &target_), "Create Direct2D target bitmap");
        surfaceWidth_ = width;
        surfaceHeight_ = height;
    }

    std::vector<uint8_t> Readback(UINT32 width, UINT32 height) {
        d3dContext_->CopyResource(staging_.Get(), texture_.Get());
        D3D11_MAPPED_SUBRESOURCE mapped{};
        Check(d3dContext_->Map(staging_.Get(), 0, D3D11_MAP_READ, 0, &mapped), "Map emoji render result");
        std::vector<uint8_t> out(static_cast<size_t>(width) * height * 4);
        for (UINT32 y = 0; y < height; ++y) {
            const auto* row = static_cast<const uint8_t*>(mapped.pData) + static_cast<size_t>(y) * mapped.RowPitch;
            std::copy(row, row + static_cast<size_t>(width) * 4, out.begin() + static_cast<size_t>(y) * width * 4);
        }
        d3dContext_->Unmap(staging_.Get(), 0);
        return out;
    }

    static Bounds FindInkBounds(const std::vector<uint8_t>& pixels, UINT32 width, UINT32 height) {
        Bounds result;
        result.left = width;
        result.top = height;
        for (UINT32 y = 0; y < height; ++y) {
            for (UINT32 x = 0; x < width; ++x) {
                const size_t at = (static_cast<size_t>(y) * width + x) * 4;
                const uint8_t b = pixels[at];
                const uint8_t g = pixels[at + 1];
                const uint8_t r = pixels[at + 2];
                const uint8_t a = pixels[at + 3];
                if (a == 0) continue;
                result.hasInk = true;
                ++result.inkPixels;
                if (b != g || g != r) ++result.colorPixels;
                result.left = std::min(result.left, x);
                result.top = std::min(result.top, y);
                result.right = std::max(result.right, x + 1);
                result.bottom = std::max(result.bottom, y + 1);
            }
        }
        return result;
    }

    static std::vector<uint8_t> Crop(const std::vector<uint8_t>& source, UINT32 sourceWidth, const Bounds& bounds) {
        std::vector<uint8_t> out(static_cast<size_t>(bounds.width()) * bounds.height() * 4);
        for (UINT32 y = 0; y < bounds.height(); ++y) {
            const size_t from = (static_cast<size_t>(bounds.top + y) * sourceWidth + bounds.left) * 4;
            const size_t to = static_cast<size_t>(y) * bounds.width() * 4;
            std::copy(source.begin() + static_cast<std::ptrdiff_t>(from),
                      source.begin() + static_cast<std::ptrdiff_t>(from + static_cast<size_t>(bounds.width()) * 4),
                      out.begin() + static_cast<std::ptrdiff_t>(to));
        }
        return out;
    }

    void WritePng(const fs::path& output, const std::vector<uint8_t>& pbgra, UINT32 width, UINT32 height) {
        ComPtr<IWICStream> stream;
        Check(wic_->CreateStream(&stream), "Create WIC stream");
        Check(stream->InitializeFromFilename(output.c_str(), GENERIC_WRITE), "Open PNG output");
        ComPtr<IWICBitmapEncoder> encoder;
        Check(wic_->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder), "Create PNG encoder");
        Check(encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache), "Initialize PNG encoder");
        ComPtr<IWICBitmapFrameEncode> frame;
        ComPtr<IPropertyBag2> properties;
        Check(encoder->CreateNewFrame(&frame, &properties), "Create PNG frame");
        Check(frame->Initialize(properties.Get()), "Initialize PNG frame");
        Check(frame->SetSize(width, height), "Set PNG size");
        WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGRA;
        Check(frame->SetPixelFormat(&format), "Set PNG pixel format");
        if (format != GUID_WICPixelFormat32bppBGRA) throw Failure("WIC PNG encoder did not retain BGRA transparency");
        ComPtr<IWICBitmap> bitmap;
        Check(wic_->CreateBitmapFromMemory(width, height, GUID_WICPixelFormat32bppPBGRA, width * 4,
                                            static_cast<UINT>(pbgra.size()), const_cast<BYTE*>(pbgra.data()), &bitmap),
              "Create WIC bitmap from Direct2D pixels");
        ComPtr<IWICFormatConverter> converter;
        Check(wic_->CreateFormatConverter(&converter), "Create WIC format converter");
        Check(converter->Initialize(bitmap.Get(), GUID_WICPixelFormat32bppBGRA, WICBitmapDitherTypeNone, nullptr,
                                    0.0, WICBitmapPaletteTypeCustom),
              "Unpremultiply PNG pixels");
        Check(frame->WriteSource(converter.Get(), nullptr), "Write PNG source");
        Check(frame->Commit(), "Commit PNG frame");
        Check(encoder->Commit(), "Commit PNG encoder");
    }

    static float Sum(const std::vector<float>& values) {
        float total = 0.0f;
        for (const float value : values) total += value;
        return total;
    }

    void PrintShapeDiagnostic(const char* source, const Request& request, float size, const Shaped& shaped) const {
        std::cerr << "EmojiRender diagnose " << source << "-glyphs id=" << request.id << " size=" << size
                  << " glyphs=";
        for (size_t i = 0; i < shaped.glyphs.size(); ++i) {
            if (i != 0) std::cerr << ',';
            std::cerr << shaped.glyphs[i] << "@0x" << std::hex << static_cast<UINT32>(shaped.formats[i]) << std::dec
                      << ":adv=" << shaped.advances[i];
        }
        std::cerr << "\n";
    }

    void ProbeOutlineDraw(const Request& request, const Shaped& shaped, UINT32 width, UINT32 height, float originX,
                          float baselineY) {
        ComPtr<ID2D1PathGeometry> geometry;
        Check(d2dFactory_->CreatePathGeometry(&geometry), "Create diagnostic outline geometry");
        ComPtr<ID2D1GeometrySink> sink;
        Check(geometry->Open(&sink), "Open diagnostic outline geometry");
        const HRESULT outlineHr = face_->GetGlyphRunOutline(layoutFontSize_, shaped.glyphs.data(), shaped.advances.data(),
                                                            shaped.offsets.data(), static_cast<UINT32>(shaped.glyphs.size()),
                                                            FALSE, FALSE, sink.Get());
        const HRESULT closeHr = sink->Close();
        D2D1_RECT_F outlineBounds{};
        const HRESULT boundsHr = SUCCEEDED(outlineHr) && SUCCEEDED(closeHr)
                                     ? geometry->GetBounds(nullptr, &outlineBounds)
                                     : E_FAIL;
        std::cerr << "EmojiRender diagnose outline-api id=" << request.id << " result=" << HrText(outlineHr)
                  << " close=" << HrText(closeHr) << " bounds=" << HrText(boundsHr) << " [" << outlineBounds.left
                  << ',' << outlineBounds.top << ',' << outlineBounds.right << ',' << outlineBounds.bottom << "]\n";
        context4_->SetTarget(target_.Get());
        context4_->SetTransform(D2D1::Matrix3x2F::Identity());
        DWRITE_GLYPH_RUN run{};
        run.fontFace = face_.Get();
        run.fontEmSize = Sum(shaped.advances) == 0.0f ? 1.0f : layoutFontSize_;
        run.glyphCount = static_cast<UINT32>(shaped.glyphs.size());
        run.glyphIndices = shaped.glyphs.data();
        run.glyphAdvances = shaped.advances.data();
        run.glyphOffsets = shaped.offsets.data();
        run.isSideways = FALSE;
        run.bidiLevel = 0;
        context4_->BeginDraw();
        context4_->Clear(D2D1_COLOR_F{0.0f, 0.0f, 0.0f, 0.0f});
        context4_->DrawGlyphRun(D2D1::Point2F(originX, baselineY), &run, brush_.Get(), DWRITE_MEASURING_MODE_NATURAL);
        Check(context4_->EndDraw(), "Diagnostic DrawGlyphRun");
        const Bounds manual = FindInkBounds(Readback(width, height), width, height);
        std::cerr << "EmojiRender diagnose direct-outline id=" << request.id << " ink=" << manual.inkPixels
                  << " color=" << manual.colorPixels << "\n";
    }

    const Options& options_;
    bool customCollection_ = false;
    std::wstring family_;
    std::wstring matchedPath_;
    ComPtr<IWICImagingFactory> wic_;
    ComPtr<IDWriteFactory5> factory_;
    ComPtr<IDWriteFontCollection> collection_;
    UINT32 familyIndex_ = 0;
    ComPtr<IDWriteFontFamily> fontFamily_;
    ComPtr<IDWriteFont> font_;
    ComPtr<IDWriteFontFace> face_;
    ComPtr<IDWriteFontFace4> face4_;
    ComPtr<IDWriteTextAnalyzer> analyzer_;
    ComPtr<IDWriteFontFallback> noFallback_;
    ComPtr<IDWriteTextFormat> format_;
    ComPtr<IDWriteTextLayout> layout_;
    float layoutFontSize_ = 0.0f;
    ComPtr<ID3D11Device> d3d_;
    ComPtr<ID3D11DeviceContext> d3dContext_;
    ComPtr<ID2D1Factory3> d2dFactory_;
    ComPtr<ID2D1Device> d2dDevice_;
    ComPtr<ID2D1DeviceContext4> context4_;
    ComPtr<ID2D1SolidColorBrush> brush_;
    ComPtr<ID3D11Texture2D> texture_;
    ComPtr<ID3D11Texture2D> staging_;
    ComPtr<ID2D1Bitmap1> target_;
    UINT32 surfaceWidth_ = 0;
    UINT32 surfaceHeight_ = 0;
};

void WriteManifest(const fs::path& output, const Options& options, const Renderer* renderer,
                   const std::vector<Request>& requests, const std::vector<std::vector<Renderer::Image>>& images,
                   const std::string& status, const std::string& error) {
    fs::create_directories(output);
    std::ofstream file(output / "render.json", std::ios::binary | std::ios::trunc);
    if (!file) throw Failure("Cannot write render.json");
    file << "{\n  \"schemaVersion\": 1,\n  \"status\": " << Json(status) << ",\n  \"font\": "
         << JsonW(options.font == L"@system" ? options.font : AbsolutePath(options.font)) << ",\n";
    if (renderer != nullptr) {
        file << "  \"fontMatched\": true,\n  \"fontmatch\": {\"mode\": " << Json(renderer->customCollection() ? "private" : "system")
             << ", \"family\": " << JsonW(renderer->family()) << ", \"facePath\": "
             << JsonW(renderer->matchedPath()) << ", \"exact\": true},\n";
    }
    if (!error.empty()) file << "  \"error\": " << Json(error) << ",\n";
    file << "  \"items\": [";
    for (size_t i = 0; i < requests.size(); ++i) {
        if (i != 0) file << ',';
        file << "\n    {\"id\": " << Json(requests[i].id) << ", \"codepoints\": "
             << Json(requests[i].normalizedCodepoints) << ", \"images\": [";
        if (i < images.size()) {
            for (size_t j = 0; j < images[i].size(); ++j) {
                const auto& image = images[i][j];
                if (j != 0) file << ',';
                const fs::path relative = fs::relative(image.path, output);
                file << "{\"size\": " << std::fixed << std::setprecision(2) << options.sizes[j]
                     << ", \"path\": " << Json(relative.generic_string()) << ", \"width\": " << image.width
                     << ", \"height\": " << image.height << ", \"advance\": " << image.advance
                     << ", \"offsetX\": " << image.offsetX << ", \"offsetY\": " << image.offsetY
                     << ", \"inkPixels\": " << image.inkPixels << ", \"colorPixels\": " << image.colorPixels
                     << ", \"glyphCount\": " << image.glyphs.size() << ", \"glyphIndices\": [";
                for (size_t k = 0; k < image.glyphs.size(); ++k) {
                    if (k != 0) file << ',';
                    file << image.glyphs[k];
                }
                file << "], \"visibleGlyphCount\": " << image.visibleGlyphCount << "}";
            }
        }
        file << "]}";
    }
    file << "\n  ]\n}\n";
}

int Run(int argc, wchar_t** argv) {
    const Options options = ParseOptions(argc, argv);
    std::vector<Request> requests;
    std::vector<std::vector<Renderer::Image>> allImages;
    std::unique_ptr<Renderer> renderer;
    try {
        requests = ReadRequests(options.requests);
        renderer = std::make_unique<Renderer>(options);
        for (const Request& request : requests) {
            std::vector<Renderer::Image> requestImages;
            for (const float size : options.sizes) {
                renderer->PrepareLayout(request, size);
                const fs::path imagePath = options.out / "images" / request.id /
                                           (std::to_string(static_cast<int>(std::lround(size))) + ".png");
                requestImages.push_back(renderer->Render(request, size, imagePath));
            }
            allImages.push_back(std::move(requestImages));
        }
        WriteManifest(options.out, options, renderer.get(), requests, allImages, "passed", "");
    } catch (const std::exception& e) {
        try {
            WriteManifest(options.out, options, renderer.get(), requests, allImages, "failed", e.what());
        } catch (...) {
            // The original error remains the useful diagnosis when output itself cannot be written.
        }
        throw;
    }
    return 0;
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
    HRESULT co = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(co)) {
        std::cerr << "Cannot initialize COM: " << HrText(co) << "\n";
        return 1;
    }
    try {
        const int result = Run(argc, argv);
        CoUninitialize();
        return result;
    } catch (const std::exception& e) {
        std::cerr << "EmojiRender failed: " << e.what() << "\n";
        CoUninitialize();
        return 1;
    }
}
