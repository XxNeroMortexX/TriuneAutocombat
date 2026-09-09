#include <mq/Plugin.h>
#include <cpr/cpr.h>

#include <string>
#include <vector>
#include <algorithm>
#include <cctype>
#include <fstream>
#include <sstream>
#include <filesystem>
#include <chrono>
#include <ctime>
#include <iomanip>
#include <thread>
#include <mutex>
#include <atomic>

PreSetup("MQ2WebUpdate");

namespace
{
    namespace fs = std::filesystem;

    struct RemoteFile
    {
        std::string repoPath;
        std::string fileName;
    };
struct FileResult
{
    std::string fileName;
    std::string repoPath;
    std::string status;
    std::string protection;
};
struct CompareWorkerResult
{
    bool success = false;

    std::string operation = "compare";
    std::string status;
    std::string remoteSha;
    std::string lastError;

    std::vector<RemoteFile> remoteFiles;
    std::vector<FileResult> fileResults;

    size_t sameCount = 0;
    size_t updateCount = 0;
    size_t missingCount = 0;
    size_t protectedCount = 0;
    size_t errorCount = 0;

    size_t stagedUpdateCount = 0;
    size_t stagedMissingCount = 0;

    std::string runtimeLuaDirectory;
    std::string stageDirectory;
};

std::thread g_compareThread;
std::mutex g_compareMutex;
std::atomic_bool g_compareRunning{ false };
bool g_compareResultReady = false;
CompareWorkerResult g_compareCompletedResult;

    std::string g_status = "Idle";
    std::string g_remoteSha;
    std::string g_lastError;
    std::vector<RemoteFile> g_remoteFiles;
std::vector<FileResult> g_fileResults;

size_t g_sameCount = 0;
size_t g_updateCount = 0;
size_t g_missingCount = 0;
size_t g_protectedCount = 0;
size_t g_errorCount = 0;

    constexpr const char* kOwner = "XxNeroMortexX";
    constexpr const char* kRepo = "TriuneAutocombat";
    constexpr const char* kBranch = "main";
    constexpr const char* kLuaPrefix = "TAC/lua/";

    cpr::Response GitHubGet(const std::string& url)
    {
        return cpr::Get(
            cpr::Url{ url },
            cpr::Header{
                { "User-Agent", "MQ2WebUpdate" },
                { "Accept", "application/vnd.github+json" }
            },
            cpr::Timeout{ 15000 }
        );
    }

    bool CheckResponse(const cpr::Response& response)
    {
        if (response.error)
        {
            g_status = "Error";
            g_lastError = response.error.message;

            WriteChatf(
                "\ar[MQ2WebUpdate]\ax HTTP error: %s",
                g_lastError.c_str()
            );

            return false;
        }

        if (response.status_code != 200)
        {
            g_status = "Error";
            g_lastError =
                "GitHub returned HTTP " +
                std::to_string(response.status_code);

            WriteChatf(
                "\ar[MQ2WebUpdate]\ax %s",
                g_lastError.c_str()
            );

            return false;
        }

        return true;
    }

    std::string ExtractJsonString(
        const std::string& json,
        const std::string& key)
    {
        const std::string needle = "\"" + key + "\"";

        auto keyPos = json.find(needle);
        if (keyPos == std::string::npos)
            return {};

        auto colonPos =
            json.find(':', keyPos + needle.size());

        if (colonPos == std::string::npos)
            return {};

        auto firstQuote =
            json.find('"', colonPos + 1);

        if (firstQuote == std::string::npos)
            return {};

        auto secondQuote =
            json.find('"', firstQuote + 1);

        if (secondQuote == std::string::npos)
            return {};

        return json.substr(
            firstQuote + 1,
            secondQuote - firstQuote - 1
        );
    }

    bool CheckRemoteSha(bool announce = true)
    {
        g_status = "Checking";
        g_remoteSha.clear();
        g_lastError.clear();

        const std::string url =
            std::string("https://api.github.com/repos/") +
            kOwner + "/" + kRepo +
            "/commits/" + kBranch;

        auto response = GitHubGet(url);

        if (!CheckResponse(response))
            return false;

        g_remoteSha =
            ExtractJsonString(response.text, "sha");

        if (g_remoteSha.empty())
        {
            g_status = "Error";
            g_lastError =
                "Could not parse commit SHA.";

            WriteChatf(
                "\ar[MQ2WebUpdate]\ax %s",
                g_lastError.c_str()
            );

            return false;
        }

        g_status = "Ready";

        if (announce)
        {
            WriteChatf(
                "\ag[MQ2WebUpdate]\ax Remote %s/%s %s SHA:",
                kOwner,
                kRepo,
                kBranch
            );

            WriteChatf(
                "\at[MQ2WebUpdate]\ax %s",
                g_remoteSha.c_str()
            );
        }

        return true;
    }

    bool ScanRemoteLuaFiles(bool announceFiles = true)
    {
        g_status = "Scanning";
        g_lastError.clear();
        g_remoteFiles.clear();

        if (!CheckRemoteSha(false))
            return false;

        const std::string url =
            std::string("https://api.github.com/repos/") +
            kOwner + "/" + kRepo +
            "/git/trees/" + g_remoteSha +
            "?recursive=1";

        auto response = GitHubGet(url);

        if (!CheckResponse(response))
            return false;

        const std::string pathNeedle = "\"path\"";
        size_t pos = 0;

        while (true)
        {
            pos = response.text.find(pathNeedle, pos);

            if (pos == std::string::npos)
                break;

            auto colonPos =
                response.text.find(
                    ':',
                    pos + pathNeedle.size()
                );

            if (colonPos == std::string::npos)
                break;

            auto firstQuote =
                response.text.find(
                    '"',
                    colonPos + 1
                );

            if (firstQuote == std::string::npos)
                break;

            auto secondQuote =
                response.text.find(
                    '"',
                    firstQuote + 1
                );

            if (secondQuote == std::string::npos)
                break;

            std::string path =
                response.text.substr(
                    firstQuote + 1,
                    secondQuote - firstQuote - 1
                );

            if (path.rfind(kLuaPrefix, 0) == 0)
            {
                std::string relative =
                    path.substr(
                        std::string(kLuaPrefix).size()
                    );

                if (!relative.empty() &&
                    relative.back() != '/')
                {
                    RemoteFile file;
                    file.repoPath = path;
                    file.fileName = relative;

                    g_remoteFiles.push_back(file);
                }
            }

            pos = secondQuote + 1;
        }

        std::sort(
            g_remoteFiles.begin(),
            g_remoteFiles.end(),
            [](const RemoteFile& a, const RemoteFile& b)
            {
                return a.repoPath < b.repoPath;
            }
        );

        g_remoteFiles.erase(
            std::unique(
                g_remoteFiles.begin(),
                g_remoteFiles.end(),
                [](const RemoteFile& a, const RemoteFile& b)
                {
                    return a.repoPath == b.repoPath;
                }
            ),
            g_remoteFiles.end()
        );

        if (g_remoteFiles.empty())
        {
            g_status = "Error";
            g_lastError =
                "No files found under TAC/lua/.";

            WriteChatf(
                "\ar[MQ2WebUpdate]\ax %s",
                g_lastError.c_str()
            );

            return false;
        }

        g_status = "Scan Ready";

        if (announceFiles)
        {
            WriteChatf(
                "\ag[MQ2WebUpdate]\ax Found %zu Lua file(s):",
                g_remoteFiles.size()
            );

            for (const auto& file : g_remoteFiles)
            {
                WriteChatf(
                    "\at[MQ2WebUpdate]\ax %s",
                    file.repoPath.c_str()
                );
            }

            WriteChatf(
                "\ag[MQ2WebUpdate]\ax Scan complete. No files changed."
            );
        }

        return true;
    }

    fs::path GetRuntimeLuaDirectory()
    {
        /*
            Derive the MQ2 runtime directory from this loaded
            plugin DLL itself.

            Example:

              ...\build\bin\release\plugins\MQ2WebUpdate.dll

            Plugin folder:
              ...\build\bin\release\plugins

            Runtime root:
              ...\build\bin\release

            Lua folder:
              ...\build\bin\release\lua
        */

        HMODULE module = nullptr;

        if (!GetModuleHandleExA(
                GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                reinterpret_cast<LPCSTR>(&GetRuntimeLuaDirectory),
                &module))
        {
            return {};
        }

        char modulePath[MAX_PATH] = {};

        DWORD len =
            GetModuleFileNameA(
                module,
                modulePath,
                MAX_PATH
            );

        if (len == 0 || len >= MAX_PATH)
            return {};

        fs::path pluginDll =
            fs::path(modulePath);

        fs::path pluginDirectory =
            pluginDll.parent_path();

        fs::path runtimeRoot =
            pluginDirectory.parent_path();

        fs::path luaDirectory =
            runtimeRoot / "lua";

        std::error_code ec;

        if (fs::exists(luaDirectory, ec) &&
            fs::is_directory(luaDirectory, ec))
        {
            return luaDirectory;
        }

        return {};
    }

    std::string NormalizeTextLineEndings(const std::string& input)
    {
        std::string output;
        output.reserve(input.size());

        for (size_t i = 0; i < input.size(); ++i)
        {
            if (input[i] == '\r')
            {
                if (i + 1 < input.size() &&
                    input[i + 1] == '\n')
                {
                    ++i;
                }

                output.push_back('\n');
            }
            else
            {
                output.push_back(input[i]);
            }
        }

        return output;
    }

    bool IsReparsePoint(const fs::path& path)
    {
        DWORD attributes = GetFileAttributesW(path.wstring().c_str());

        if (attributes == INVALID_FILE_ATTRIBUTES)
        {
            return false;
        }

        return (attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0;
    }

    bool ReadFileBinary(
        const fs::path& path,
        std::string& data)
    {
        std::ifstream file(
            path,
            std::ios::binary
        );

        if (!file)
            return false;

        std::ostringstream buffer;
        buffer << file.rdbuf();

        data = buffer.str();

        return true;
    }

    std::string RawGitHubUrl(
        const std::string& repoPath)
    {
        return
            std::string("https://raw.githubusercontent.com/") +
            kOwner + "/" +
            kRepo + "/" +
            g_remoteSha + "/" +
            repoPath;
    }

    bool CompareRemoteLuaFiles()
    {
        g_status = "Comparing";
        g_lastError.clear();

        WriteChatf(
            "\ag[MQ2WebUpdate]\ax Discovering remote Lua files..."
        );

        if (!ScanRemoteLuaFiles(false))
            return false;

        fs::path luaDirectory =
            GetRuntimeLuaDirectory();

        if (luaDirectory.empty())
        {
            g_status = "Error";
            g_lastError =
                "Could not locate MQ2 runtime Lua directory.";

            WriteChatf(
                "\ar[MQ2WebUpdate]\ax %s",
                g_lastError.c_str()
            );

            return false;
        }

        WriteChatf(
            "\ay[MQ2WebUpdate]\ax Runtime Lua folder:"
        );

        WriteChatf(
            "\at[MQ2WebUpdate]\ax %s",
            luaDirectory.string().c_str()
        );

        WriteChatf(
            "\ay[MQ2WebUpdate]\ax Comparing against commit:"
        );

        WriteChatf(
            "\at[MQ2WebUpdate]\ax %s",
            g_remoteSha.c_str()
        );

        size_t sameCount = 0;
        size_t updateCount = 0;
        size_t missingCount = 0;
        size_t errorCount = 0;

        for (const auto& remote : g_remoteFiles)
        {
            /*
                TAC/lua/foo.lua
                       ?
                <MQ2 runtime>/lua/foo.lua
            */

            fs::path localPath =
                luaDirectory /
                fs::path(remote.fileName);

            auto response =
                GitHubGet(
                    RawGitHubUrl(remote.repoPath)
                );

            if (!CheckResponse(response))
            {
                ++errorCount;

                WriteChatf(
                    "\ar[MQ2WebUpdate]\ax ERROR    %s",
                    remote.fileName.c_str()
                );

                continue;
            }

            std::error_code ec;

            if (!fs::exists(localPath, ec))
            {
                ++missingCount;

                WriteChatf(
                    "\ay[MQ2WebUpdate]\ax MISSING  %s",
                    remote.fileName.c_str()
                );

                continue;
            }

            std::string localData;

            if (!ReadFileBinary(
                    localPath,
                    localData))
            {
                ++errorCount;

                WriteChatf(
                    "\ar[MQ2WebUpdate]\ax ERROR    %s - could not read local file",
                    remote.fileName.c_str()
                );

                continue;
            }

            if (NormalizeTextLineEndings(localData) ==
                NormalizeTextLineEndings(response.text))
            {
                ++sameCount;

                WriteChatf(
                    "\ag[MQ2WebUpdate]\ax SAME     %s",
                    remote.fileName.c_str()
                );
            }
            else
            {
                ++updateCount;

                WriteChatf(
                    "\ao[MQ2WebUpdate]\ax UPDATE   %s",
                    remote.fileName.c_str()
                );
            }
        }

        WriteChatf(
            "\ay[MQ2WebUpdate]\ax ------------------------------"
        );

        WriteChatf(
            "\ay[MQ2WebUpdate]\ax Remote files: %zu",
            g_remoteFiles.size()
        );

        WriteChatf(
            "\ag[MQ2WebUpdate]\ax Same: %zu",
            sameCount
        );

        WriteChatf(
            "\ao[MQ2WebUpdate]\ax Update: %zu",
            updateCount
        );

        WriteChatf(
            "\ay[MQ2WebUpdate]\ax Missing: %zu",
            missingCount
        );

        if (errorCount > 0)
        {
            WriteChatf(
                "\ar[MQ2WebUpdate]\ax Errors: %zu",
                errorCount
            );
        }

        WriteChatf(
            "\ag[MQ2WebUpdate]\ax Compare complete. No files changed."
        );

        if (errorCount > 0)
            g_status = "Compare Error";
        else if (updateCount > 0 ||
                 missingCount > 0)
            g_status = "Update Available";
        else
            g_status = "Up To Date";

        return errorCount == 0;
    }

    bool WriteFileBinary(
        const fs::path& path,
        const std::string& data)
    {
        std::error_code ec;

        fs::create_directories(
            path.parent_path(),
            ec
        );

        if (ec)
            return false;

        std::ofstream file(
            path,
            std::ios::binary |
            std::ios::trunc
        );

        if (!file)
            return false;

        file.write(
            data.data(),
            static_cast<std::streamsize>(data.size())
        );

        return file.good();
    }

    bool CompareRemoteLuaFilesStructured();

    struct StageMetadata
    {
        std::string repository;
        std::string branch;
        std::string sha;
    };

    bool IsValidGitSha(const std::string& sha)
    {
        if (sha.size() != 40)
            return false;

        for (unsigned char ch : sha)
        {
            if (!std::isxdigit(ch))
                return false;
        }

        return true;
    }

    std::string MakeTimestamp()
    {
        const auto now =
            std::chrono::system_clock::now();

        const std::time_t nowTime =
            std::chrono::system_clock::to_time_t(now);

        std::tm localTime = {};

        if (localtime_s(&localTime, &nowTime) != 0)
            return "unknown-time";

        std::ostringstream out;

        out << std::put_time(
            &localTime,
            "%Y%m%d-%H%M%S"
        );

        return out.str();
    }

    bool WriteStageMetadata(
        const fs::path& metadataPath,
        const std::string& sha)
    {
        std::ostringstream data;

        data
            << "Repository="
            << kOwner << "/" << kRepo << "\n"
            << "Branch="
            << kBranch << "\n"
            << "SHA="
            << sha << "\n";

        return WriteFileBinary(
            metadataPath,
            data.str()
        );
    }

    bool ReadStageMetadata(
        const fs::path& metadataPath,
        StageMetadata& metadata)
    {
        std::string data;

        if (!ReadFileBinary(
                metadataPath,
                data))
        {
            return false;
        }

        std::istringstream input(data);
        std::string line;

        while (std::getline(input, line))
        {
            if (!line.empty() &&
                line.back() == '\r')
            {
                line.pop_back();
            }

            const auto equals =
                line.find('=');

            if (equals == std::string::npos)
                continue;

            const std::string key =
                line.substr(0, equals);

            const std::string value =
                line.substr(equals + 1);

            if (key == "Repository")
                metadata.repository = value;
            else if (key == "Branch")
                metadata.branch = value;
            else if (key == "SHA")
                metadata.sha = value;
        }

        if (metadata.repository !=
                std::string(kOwner) + "/" + kRepo)
        {
            return false;
        }

        if (metadata.branch != kBranch)
            return false;

        if (metadata.sha.empty())
            return false;

        return true;
    }
    bool StageRemoteLuaFiles()
    {
        g_status = "Staging";
        g_lastError.clear();

        WriteChatf(
            "\ag[MQ2WebUpdate]\ax Preparing update staging area..."
        );

        /*
            Always perform a structured comparison before staging.

            This guarantees the Lua GUI has current file-by-file
            results and summary counters even when /webupdate stage
            is run directly without a previous compare.
        */
        if (!CompareRemoteLuaFilesStructured())
        {
            g_status = "Stage Error";

            if (g_lastError.empty())
            {
                g_lastError =
                    "Pre-stage comparison failed.";
            }

            WriteChatf(
                "\ar[MQ2WebUpdate]\ax Staging aborted because comparison failed."
            );

            return false;
        }

        /*
            CompareRemoteLuaFilesStructured() refreshed:
              g_remoteSha
              g_remoteFiles
              g_fileResults
              all GUI summary counters

            Stage now uses that exact comparison snapshot.
        */
        g_status = "Staging";

        fs::path luaDirectory =
            GetRuntimeLuaDirectory();

        if (luaDirectory.empty())
        {
            g_status = "Error";
            g_lastError =
                "Could not locate MQ2 runtime Lua directory.";

            WriteChatf(
                "\ar[MQ2WebUpdate]\ax %s",
                g_lastError.c_str()
            );

            return false;
        }

        fs::path runtimeRoot =
            luaDirectory.parent_path();

        fs::path stageRoot =
            runtimeRoot /
            "webupdate_stage" /
            "TriuneAutocombat";

        /*
            A stage is one exact GitHub transaction.

            Clear any previous Triune staging transaction before
            creating the new SHA-specific stage. This prevents an
            old staged Lua file from surviving into a newer update.
        */
        std::error_code stageEc;

        fs::remove_all(
            stageRoot,
            stageEc
        );

        if (stageEc)
        {
            g_status = "Stage Error";
            g_lastError =
                "Could not clear previous staging transaction.";

            WriteChatf(
                "\ar[MQ2WebUpdate]\ax %s",
                g_lastError.c_str()
            );

            return false;
        }

        if (!IsValidGitSha(g_remoteSha))
        {
            g_status = "Stage Error";
            g_lastError =
                "Remote commit SHA is invalid.";

            WriteChatf(
                "\ar[MQ2WebUpdate]\ax %s",
                g_lastError.c_str()
            );

            return false;
        }

        fs::path stageDirectory =
            stageRoot /
            g_remoteSha;

        fs::create_directories(
            stageDirectory,
            stageEc
        );

        if (stageEc)
        {
            g_status = "Stage Error";
            g_lastError =
                "Could not create SHA staging directory.";

            WriteChatf(
                "\ar[MQ2WebUpdate]\ax %s",
                g_lastError.c_str()
            );

            return false;
        }

        fs::path metadataPath =
            stageRoot /
            "stage.ini";

        WriteChatf(
            "\ay[MQ2WebUpdate]\ax Stage folder: %s",
            stageDirectory.string().c_str()
        );

        WriteChatf(
            "\ay[MQ2WebUpdate]\ax Remote commit: %s",
            g_remoteSha.c_str()
        );

        size_t sameCount = 0;
        size_t stagedUpdateCount = 0;
        size_t stagedMissingCount = 0;
        size_t protectedCount = 0;
        size_t errorCount = 0;

        for (const auto& remote : g_remoteFiles)
        {
            fs::path localPath =
                luaDirectory / remote.fileName;

            fs::path stagePath =
                stageDirectory / remote.fileName;

            auto response =
                GitHubGet(
                    RawGitHubUrl(remote.repoPath)
                );

            if (!CheckResponse(response))
            {
                ++errorCount;

                WriteChatf(
                    "\ar[MQ2WebUpdate]\ax %s: DOWNLOAD ERROR",
                    remote.fileName.c_str()
                );

                continue;
            }

            std::error_code ec;
            bool localExists =
                fs::exists(localPath, ec);

            bool localProtected =
                localExists &&
                IsReparsePoint(localPath);

            if (localProtected)
                ++protectedCount;

            if (localExists)
            {
                std::string localData;

                if (!ReadFileBinary(
                        localPath,
                        localData))
                {
                    ++errorCount;

                    WriteChatf(
                        "\ar[MQ2WebUpdate]\ax %s: LOCAL READ ERROR",
                        remote.fileName.c_str()
                    );

                    continue;
                }

                if (NormalizeTextLineEndings(localData) ==
                    NormalizeTextLineEndings(response.text))
                {
                    ++sameCount;

                    WriteChatf(
                        "\ag[MQ2WebUpdate]\ax %s: SAME - NOT STAGED",
                        remote.fileName.c_str()
                    );

                    continue;
                }
            }

            if (!WriteFileBinary(
                    stagePath,
                    response.text))
            {
                ++errorCount;

                WriteChatf(
                    "\ar[MQ2WebUpdate]\ax %s: STAGE WRITE ERROR",
                    remote.fileName.c_str()
                );

                continue;
            }

            std::string verifyData;

            if (!ReadFileBinary(
                    stagePath,
                    verifyData) ||
                verifyData != response.text)
            {
                ++errorCount;

                WriteChatf(
                    "\ar[MQ2WebUpdate]\ax %s: STAGE VERIFY ERROR",
                    remote.fileName.c_str()
                );

                continue;
            }

            if (localExists)
            {
                ++stagedUpdateCount;

                if (localProtected)
                {
                    WriteChatf(
                        "\ao[MQ2WebUpdate]\ax %s: UPDATE -> STAGED (LIVE LINK PROTECTED)",
                        remote.fileName.c_str()
                    );
                }
                else
                {
                    WriteChatf(
                        "\ao[MQ2WebUpdate]\ax %s: UPDATE -> STAGED",
                        remote.fileName.c_str()
                    );
                }
            }
            else
            {
                ++stagedMissingCount;

                WriteChatf(
                    "\ay[MQ2WebUpdate]\ax %s: MISSING -> STAGED",
                    remote.fileName.c_str()
                );
            }
        }

        WriteChatf(
            "\ay[MQ2WebUpdate]\ax ------------------------------"
        );

        WriteChatf(
            "\ay[MQ2WebUpdate]\ax Remote files: %zu",
            g_remoteFiles.size()
        );

        WriteChatf(
            "\ag[MQ2WebUpdate]\ax Same / skipped: %zu",
            sameCount
        );

        WriteChatf(
            "\ao[MQ2WebUpdate]\ax Updates staged: %zu",
            stagedUpdateCount
        );

        WriteChatf(
            "\ay[MQ2WebUpdate]\ax Missing staged: %zu",
            stagedMissingCount
        );

        WriteChatf(
            "\ao[MQ2WebUpdate]\ax Protected live links seen: %zu",
            protectedCount
        );

        WriteChatf(
            "\ag[MQ2WebUpdate]\ax Live files changed: 0"
        );

        if (errorCount > 0)
        {
            WriteChatf(
                "\ar[MQ2WebUpdate]\ax Errors: %zu",
                errorCount
            );

            g_status = "Stage Error";
            g_lastError =
                "Staging did not complete successfully. No stage metadata was committed.";

            WriteChatf(
                "\ar[MQ2WebUpdate]\ax Stage is incomplete and cannot be applied."
            );

            WriteChatf(
                "\ay[MQ2WebUpdate]\ax Partial staged files were kept for diagnostics."
            );

            return false;
        }

        /*
            Commit the staging transaction LAST.

            Apply requires stage.ini. Therefore a partial or
            interrupted staging operation cannot be mistaken
            for a complete update transaction.
        */
        if (!WriteStageMetadata(
                metadataPath,
                g_remoteSha))
        {
            g_status = "Stage Error";
            g_lastError =
                "Staging completed, but stage metadata could not be committed.";

            WriteChatf(
                "\ar[MQ2WebUpdate]\ax %s",
                g_lastError.c_str()
            );

            WriteChatf(
                "\ar[MQ2WebUpdate]\ax Stage is incomplete and cannot be applied."
            );

            return false;
        }

        if (stagedUpdateCount > 0 ||
            stagedMissingCount > 0)
        {
            g_status = "Staged";
        }
        else
        {
            g_status = "Up To Date";
        }

        WriteChatf(
            "\ag[MQ2WebUpdate]\ax Stage transaction committed."
        );

        WriteChatf(
            "\ag[MQ2WebUpdate]\ax Stage complete. Live Lua files were not changed."
        );

        return true;
    }

    struct AppliedFileChange
    {
        fs::path livePath;
        fs::path backupPath;
        bool existedBefore = false;
    };

    bool ReplaceRegularFileFromData(
        const fs::path& livePath,
        const std::string& data)
    {
        fs::path tempPath = livePath;
        tempPath += ".webupdate.tmp";

        std::error_code ec;
        fs::remove(tempPath, ec);

        if (!WriteFileBinary(tempPath, data))
            return false;

        std::string verifyTemp;

        if (!ReadFileBinary(tempPath, verifyTemp) ||
            verifyTemp != data)
        {
            fs::remove(tempPath, ec);
            return false;
        }

        if (!MoveFileExW(
                tempPath.wstring().c_str(),
                livePath.wstring().c_str(),
                MOVEFILE_REPLACE_EXISTING |
                MOVEFILE_WRITE_THROUGH))
        {
            fs::remove(tempPath, ec);
            return false;
        }

        std::string verifyLive;

        if (!ReadFileBinary(livePath, verifyLive) ||
            verifyLive != data)
        {
            return false;
        }

        return true;
    }

    void RollbackAppliedFiles(
        const std::vector<AppliedFileChange>& applied)
    {
        WriteChatf(
            "\ar[MQ2WebUpdate]\ax Rolling back applied files..."
        );

        for (auto it = applied.rbegin();
             it != applied.rend();
             ++it)
        {
            std::error_code ec;

            if (it->existedBefore)
            {
                std::string backupData;

                if (ReadFileBinary(
                        it->backupPath,
                        backupData) &&
                    ReplaceRegularFileFromData(
                        it->livePath,
                        backupData))
                {
                    WriteChatf(
                        "\ay[MQ2WebUpdate]\ax Rolled back: %s",
                        it->livePath.filename()
                            .string()
                            .c_str()
                    );
                }
                else
                {
                    WriteChatf(
                        "\ar[MQ2WebUpdate]\ax ROLLBACK FAILED: %s",
                        it->livePath.filename()
                            .string()
                            .c_str()
                    );
                }
            }
            else
            {
                fs::remove(it->livePath, ec);

                if (!fs::exists(it->livePath, ec))
                {
                    WriteChatf(
                        "\ay[MQ2WebUpdate]\ax Removed newly-created file: %s",
                        it->livePath.filename()
                            .string()
                            .c_str()
                    );
                }
                else
                {
                    WriteChatf(
                        "\ar[MQ2WebUpdate]\ax ROLLBACK REMOVE FAILED: %s",
                        it->livePath.filename()
                            .string()
                            .c_str()
                    );
                }
            }
        }
    }

    bool ApplyStagedLuaFiles()
    {
        g_status = "Applying";
        g_lastError.clear();

        fs::path luaDirectory =
            GetRuntimeLuaDirectory();

        if (luaDirectory.empty())
        {
            g_status = "Error";
            g_lastError =
                "Could not locate MQ2 runtime Lua directory.";

            WriteChatf(
                "\ar[MQ2WebUpdate]\ax %s",
                g_lastError.c_str()
            );

            return false;
        }

        fs::path runtimeRoot =
            luaDirectory.parent_path();

        fs::path stageRoot =
            runtimeRoot /
            "webupdate_stage" /
            "TriuneAutocombat";

        fs::path metadataPath =
            stageRoot /
            "stage.ini";

        if (!fs::exists(stageRoot))
        {
            WriteChatf(
                "\ay[MQ2WebUpdate]\ax No staging folder exists."
            );

            g_status = "Nothing Staged";
            return true;
        }

        StageMetadata metadata;

        if (!ReadStageMetadata(
                metadataPath,
                metadata))
        {
            g_status = "Apply Error";
            g_lastError =
                "Stage metadata is missing or invalid.";

            WriteChatf(
                "\ar[MQ2WebUpdate]\ax %s",
                g_lastError.c_str()
            );

            return false;
        }

        const std::string expectedRepository =
            std::string(kOwner) + "/" + kRepo;

        if (metadata.repository != expectedRepository)
        {
            g_status = "Apply Error";
            g_lastError =
                "Stage metadata repository does not match this updater.";

            WriteChatf(
                "\ar[MQ2WebUpdate]\ax %s",
                g_lastError.c_str()
            );

            return false;
        }

        if (metadata.branch != kBranch)
        {
            g_status = "Apply Error";
            g_lastError =
                "Stage metadata branch does not match this updater.";

            WriteChatf(
                "\ar[MQ2WebUpdate]\ax %s",
                g_lastError.c_str()
            );

            return false;
        }

        if (!IsValidGitSha(metadata.sha))
        {
            g_status = "Apply Error";
            g_lastError =
                "Stage metadata contains an invalid commit SHA.";

            WriteChatf(
                "\ar[MQ2WebUpdate]\ax %s",
                g_lastError.c_str()
            );

            return false;
        }

        /*
            The staged SHA is authoritative during apply.
            This remains correct even if MQ2WebUpdate was
            unloaded/reloaded after staging.
        */
        g_remoteSha = metadata.sha;

        fs::path stageDirectory =
            stageRoot /
            metadata.sha;

        if (!fs::exists(stageDirectory))
        {
            g_status = "Apply Error";
            g_lastError =
                "SHA staging directory does not exist.";

            WriteChatf(
                "\ar[MQ2WebUpdate]\ax %s",
                g_lastError.c_str()
            );

            return false;
        }

        WriteChatf(
            "\ay[MQ2WebUpdate]\ax Stage repository: %s",
            metadata.repository.c_str()
        );

        WriteChatf(
            "\ay[MQ2WebUpdate]\ax Stage branch: %s",
            metadata.branch.c_str()
        );

        WriteChatf(
            "\ay[MQ2WebUpdate]\ax Stage SHA: %s",
            metadata.sha.c_str()
        );

        std::vector<fs::path> stagedFiles;

        std::error_code ec;

        for (const auto& entry :
             fs::recursive_directory_iterator(
                 stageDirectory,
                 ec))
        {
            if (ec)
                break;

            if (!entry.is_regular_file())
                continue;

            if (entry.path().extension() != ".lua")
                continue;

            stagedFiles.push_back(entry.path());
        }

        if (ec)
        {
            g_status = "Apply Error";
            g_lastError =
                "Could not enumerate staging directory.";

            WriteChatf(
                "\ar[MQ2WebUpdate]\ax %s",
                g_lastError.c_str()
            );

            return false;
        }

        if (stagedFiles.empty())
        {
            WriteChatf(
                "\ay[MQ2WebUpdate]\ax No staged Lua files found."
            );

            g_status = "Nothing Staged";
            return true;
        }

        const std::string backupTimestamp =
            MakeTimestamp();

        fs::path backupDirectory =
            runtimeRoot /
            "webupdate_backup" /
            "TriuneAutocombat" /
            metadata.sha /
            backupTimestamp;

        fs::create_directories(
            backupDirectory,
            ec
        );

        if (ec)
        {
            g_status = "Apply Error";
            g_lastError =
                "Could not create backup directory.";

            WriteChatf(
                "\ar[MQ2WebUpdate]\ax %s",
                g_lastError.c_str()
            );

            return false;
        }

        WriteChatf(
            "\ay[MQ2WebUpdate]\ax Applying staged Lua update..."
        );

        WriteChatf(
            "\ay[MQ2WebUpdate]\ax Stage: %s",
            stageDirectory.string().c_str()
        );

        WriteChatf(
            "\ay[MQ2WebUpdate]\ax Backup: %s",
            backupDirectory.string().c_str()
        );

        size_t appliedCount = 0;
        size_t protectedCount = 0;
        size_t errorCount = 0;

        std::vector<AppliedFileChange> applied;

        for (const auto& stagePath : stagedFiles)
        {
            fs::path relativePath =
                fs::relative(
                    stagePath,
                    stageDirectory,
                    ec
                );

            if (ec)
            {
                ++errorCount;

                WriteChatf(
                    "\ar[MQ2WebUpdate]\ax Could not determine staged relative path."
                );

                break;
            }

            fs::path livePath =
                luaDirectory / relativePath;

            fs::path backupPath =
                backupDirectory / relativePath;

            /*
                triune_updater.lua is the controller that invokes
                /webupdate apply while it is still executing.

                Never replace the controller during its own update
                transaction. The staged copy is intentionally kept
                so a future/manual controller update can be handled
                outside the running transaction.
            */
            std::string relativeName =
                relativePath.filename().string();

            std::transform(
                relativeName.begin(),
                relativeName.end(),
                relativeName.begin(),
                [](unsigned char c)
                {
                    return static_cast<char>(
                        std::tolower(c)
                    );
                }
            );

            if (relativeName == "triune_updater.lua")
            {
                ++protectedCount;

                WriteChatf(
                    "\ao[MQ2WebUpdate]\ax %s: CONTROLLER - DEFERRED - NOT APPLIED",
                    relativePath.string().c_str()
                );

                continue;
            }

            bool existedBefore =
                fs::exists(livePath, ec);

            if (ec)
            {
                ++errorCount;

                WriteChatf(
                    "\ar[MQ2WebUpdate]\ax %s: LIVE FILE CHECK ERROR",
                    relativePath.string().c_str()
                );

                break;
            }

            if (existedBefore &&
                IsReparsePoint(livePath))
            {
                ++protectedCount;

                WriteChatf(
                    "\ao[MQ2WebUpdate]\ax %s: LINK - PROTECTED - NOT APPLIED",
                    relativePath.string().c_str()
                );

                continue;
            }

            std::string stagedData;

            if (!ReadFileBinary(
                    stagePath,
                    stagedData))
            {
                ++errorCount;

                WriteChatf(
                    "\ar[MQ2WebUpdate]\ax %s: STAGED FILE READ ERROR",
                    relativePath.string().c_str()
                );

                break;
            }

            if (existedBefore)
            {
                std::string currentData;

                if (!ReadFileBinary(
                        livePath,
                        currentData))
                {
                    ++errorCount;

                    WriteChatf(
                        "\ar[MQ2WebUpdate]\ax %s: LIVE FILE READ ERROR",
                        relativePath.string().c_str()
                    );

                    break;
                }

                fs::create_directories(
                    backupPath.parent_path(),
                    ec
                );

                if (ec ||
                    !WriteFileBinary(
                        backupPath,
                        currentData))
                {
                    ++errorCount;

                    WriteChatf(
                        "\ar[MQ2WebUpdate]\ax %s: BACKUP WRITE ERROR",
                        relativePath.string().c_str()
                    );

                    break;
                }

                std::string verifyBackup;

                if (!ReadFileBinary(
                        backupPath,
                        verifyBackup) ||
                    verifyBackup != currentData)
                {
                    ++errorCount;

                    WriteChatf(
                        "\ar[MQ2WebUpdate]\ax %s: BACKUP VERIFY ERROR",
                        relativePath.string().c_str()
                    );

                    break;
                }
            }

            AppliedFileChange change;
            change.livePath = livePath;
            change.backupPath = backupPath;
            change.existedBefore = existedBefore;

            applied.push_back(change);

            if (!ReplaceRegularFileFromData(
                    livePath,
                    stagedData))
            {
                ++errorCount;

                WriteChatf(
                    "\ar[MQ2WebUpdate]\ax %s: APPLY OR VERIFY ERROR",
                    relativePath.string().c_str()
                );

                break;
            }

            ++appliedCount;

            if (existedBefore)
            {
                WriteChatf(
                    "\ag[MQ2WebUpdate]\ax %s: UPDATED + VERIFIED",
                    relativePath.string().c_str()
                );
            }
            else
            {
                WriteChatf(
                    "\ag[MQ2WebUpdate]\ax %s: CREATED + VERIFIED",
                    relativePath.string().c_str()
                );
            }
        }

        if (errorCount > 0)
        {
            RollbackAppliedFiles(applied);

            g_status = "Apply Failed";
            g_lastError =
                "Apply failed. Rollback attempted. Stage and backups were kept.";

            WriteChatf(
                "\ar[MQ2WebUpdate]\ax Apply failed."
            );

            WriteChatf(
                "\ar[MQ2WebUpdate]\ax Stage and backups were NOT deleted."
            );

            return false;
        }

        WriteChatf(
            "\ay[MQ2WebUpdate]\ax ------------------------------"
        );

        WriteChatf(
            "\ag[MQ2WebUpdate]\ax Applied + verified: %zu",
            appliedCount
        );

        WriteChatf(
            "\ao[MQ2WebUpdate]\ax Protected links skipped: %zu",
            protectedCount
        );

        WriteChatf(
            "\ag[MQ2WebUpdate]\ax Errors: 0"
        );

        if (protectedCount > 0)
        {
            g_status = "Partial - Protected Links";

            WriteChatf(
                "\ao[MQ2WebUpdate]\ax Staging was kept because protected files were not applied."
            );

            WriteChatf(
                "\ag[MQ2WebUpdate]\ax No protected link was modified."
            );

            return true;
        }

        ec.clear();

        fs::remove_all(
            stageRoot,
            ec
        );

        if (ec)
        {
            g_status = "Applied - Cleanup Warning";

            WriteChatf(
                "\ay[MQ2WebUpdate]\ax Update applied successfully, but staging cleanup failed."
            );

            WriteChatf(
                "\ay[MQ2WebUpdate]\ax Stage folder: %s",
                stageDirectory.string().c_str()
            );

            return true;
        }

        g_status = "Applied";

        WriteChatf(
            "\ag[MQ2WebUpdate]\ax Apply complete."
        );

        WriteChatf(
            "\ag[MQ2WebUpdate]\ax Staging cleanup complete."
        );

        WriteChatf(
            "\ay[MQ2WebUpdate]\ax Backups were kept at: %s",
            backupDirectory.string().c_str()
        );

        return true;
    }

    void ShowProtection()
    {
        g_status = "Checking Protection";
        g_lastError.clear();

        fs::path luaDirectory = GetRuntimeLuaDirectory();

        if (luaDirectory.empty())
        {
            g_status = "Error";
            g_lastError = "Could not locate MQ2 runtime Lua directory.";

            WriteChatf(
                "\ar[MQ2WebUpdate]\ax %s",
                g_lastError.c_str()
            );

            return;
        }

        if (!ScanRemoteLuaFiles(false))
            return;

        WriteChatf(
            "\ag[MQ2WebUpdate]\ax Checking local Lua file protection..."
        );

        WriteChatf(
            "\ay[MQ2WebUpdate]\ax Runtime Lua folder: %s",
            luaDirectory.string().c_str()
        );

        size_t regularCount = 0;
        size_t protectedCount = 0;
        size_t missingCount = 0;

        for (const auto& remote : g_remoteFiles)
        {
            fs::path localPath =
                luaDirectory / remote.fileName;

            std::error_code ec;

            if (!fs::exists(localPath, ec))
            {
                ++missingCount;

                WriteChatf(
                    "\ay[MQ2WebUpdate]\ax %s: MISSING",
                    remote.fileName.c_str()
                );

                continue;
            }

            if (IsReparsePoint(localPath))
            {
                ++protectedCount;

                WriteChatf(
                    "\ao[MQ2WebUpdate]\ax %s: LINK - PROTECTED",
                    remote.fileName.c_str()
                );

                continue;
            }

            ++regularCount;

            WriteChatf(
                "\ag[MQ2WebUpdate]\ax %s: REGULAR",
                remote.fileName.c_str()
            );
        }

        WriteChatf(
            "\ay[MQ2WebUpdate]\ax ------------------------------"
        );

        WriteChatf(
            "\ay[MQ2WebUpdate]\ax Remote files: %zu",
            g_remoteFiles.size()
        );

        WriteChatf(
            "\ao[MQ2WebUpdate]\ax Protected links: %zu",
            protectedCount
        );

        WriteChatf(
            "\ag[MQ2WebUpdate]\ax Regular files: %zu",
            regularCount
        );

        WriteChatf(
            "\ay[MQ2WebUpdate]\ax Missing files: %zu",
            missingCount
        );

        g_status = "Protection Ready";

        WriteChatf(
            "\ag[MQ2WebUpdate]\ax Protection check complete. No files changed."
        );
    }

    bool CompareRemoteLuaFilesStructured()
{
    g_status = "Comparing";
    g_lastError.clear();

    g_fileResults.clear();

    g_sameCount = 0;
    g_updateCount = 0;
    g_missingCount = 0;
    g_protectedCount = 0;
    g_errorCount = 0;

    WriteChatf(
        "\ag[MQ2WebUpdate]\ax Discovering remote Lua files..."
    );

    if (!ScanRemoteLuaFiles(false))
        return false;

    fs::path luaDirectory =
        GetRuntimeLuaDirectory();

    if (luaDirectory.empty())
    {
        g_status = "Compare Error";
        g_lastError =
            "Could not locate MQ2 runtime Lua directory.";

        WriteChatf(
            "\ar[MQ2WebUpdate]\ax %s",
            g_lastError.c_str()
        );

        return false;
    }

    WriteChatf(
        "\ay[MQ2WebUpdate]\ax Runtime Lua folder:"
    );

    WriteChatf(
        "\at[MQ2WebUpdate]\ax %s",
        luaDirectory.string().c_str()
    );

    WriteChatf(
        "\ay[MQ2WebUpdate]\ax Comparing against commit:"
    );

    WriteChatf(
        "\at[MQ2WebUpdate]\ax %s",
        g_remoteSha.c_str()
    );

    for (const auto& remote : g_remoteFiles)
    {
        FileResult result;
        result.fileName = remote.fileName;
        result.repoPath = remote.repoPath;
        result.status = "UNKNOWN";
        result.protection = "UNKNOWN";

        fs::path localPath =
            luaDirectory / remote.fileName;

        std::error_code ec;

        const bool exists =
            fs::exists(localPath, ec);

        if (ec)
        {
            ++g_errorCount;

            result.status = "ERROR";
            result.protection = "UNKNOWN";

            g_fileResults.push_back(result);

            WriteChatf(
                "\ar[MQ2WebUpdate]\ax ERROR   %s - local file check failed",
                remote.fileName.c_str()
            );

            continue;
        }

        auto response =
            GitHubGet(
                RawGitHubUrl(remote.repoPath)
            );

        if (!CheckResponse(response))
        {
            ++g_errorCount;

            result.status = "ERROR";

            if (exists &&
                IsReparsePoint(localPath))
            {
                result.protection =
                    "LINK PROTECTED";
                ++g_protectedCount;
            }
            else if (exists)
            {
                result.protection =
                    "REGULAR";
            }
            else
            {
                result.protection =
                    "NEW FILE";
            }

            g_fileResults.push_back(result);

            WriteChatf(
                "\ar[MQ2WebUpdate]\ax ERROR   %s",
                remote.fileName.c_str()
            );

            continue;
        }

        if (!exists)
        {
            ++g_missingCount;

            result.status =
                "MISSING";

            result.protection =
                "NEW FILE";

            g_fileResults.push_back(result);

            WriteChatf(
                "\ay[MQ2WebUpdate]\ax MISSING %s",
                remote.fileName.c_str()
            );

            continue;
        }

        if (IsReparsePoint(localPath))
        {
            result.protection =
                "LINK PROTECTED";

            ++g_protectedCount;
        }
        else
        {
            result.protection =
                "REGULAR";
        }

        std::string localData;

        if (!ReadFileBinary(
                localPath,
                localData))
        {
            ++g_errorCount;

            result.status =
                "ERROR";

            g_fileResults.push_back(result);

            WriteChatf(
                "\ar[MQ2WebUpdate]\ax ERROR   %s - could not read local file",
                remote.fileName.c_str()
            );

            continue;
        }

        if (NormalizeTextLineEndings(localData) ==
            NormalizeTextLineEndings(response.text))
        {
            ++g_sameCount;

            result.status =
                "SAME";

            g_fileResults.push_back(result);

            WriteChatf(
                "\ag[MQ2WebUpdate]\ax SAME    %s",
                remote.fileName.c_str()
            );
        }
        else
        {
            ++g_updateCount;

            result.status =
                "UPDATE";

            g_fileResults.push_back(result);

            WriteChatf(
                "\ao[MQ2WebUpdate]\ax UPDATE  %s",
                remote.fileName.c_str()
            );
        }
    }

    WriteChatf(
        "\ay[MQ2WebUpdate]\ax ------------------------------"
    );

    WriteChatf(
        "\ay[MQ2WebUpdate]\ax Remote files: %zu",
        g_remoteFiles.size()
    );

    WriteChatf(
        "\ag[MQ2WebUpdate]\ax Same: %zu",
        g_sameCount
    );

    WriteChatf(
        "\ao[MQ2WebUpdate]\ax Update: %zu",
        g_updateCount
    );

    WriteChatf(
        "\ay[MQ2WebUpdate]\ax Missing: %zu",
        g_missingCount
    );

    WriteChatf(
        "\ao[MQ2WebUpdate]\ax Protected links: %zu",
        g_protectedCount
    );

    WriteChatf(
        "\ar[MQ2WebUpdate]\ax Errors: %zu",
        g_errorCount
    );

    if (g_errorCount > 0)
    {
        g_status =
            "Compare Error";
    }
    else if (g_updateCount > 0 ||
             g_missingCount > 0)
    {
        g_status =
            "Update Available";
    }
    else
    {
        g_status =
            "Up To Date";
    }

    WriteChatf(
        "\ag[MQ2WebUpdate]\ax Compare complete. No files changed."
    );

    return g_errorCount == 0;
}

class MQ2WebUpdateFileType;
class MQ2WebUpdateType;

MQ2WebUpdateFileType* pWebUpdateFileType = nullptr;
MQ2WebUpdateType* pWebUpdateType = nullptr;


class MQ2WebUpdateFileType : public MQ2Type
{
public:
    enum Members
    {
        Name = 1,
        RepoPath,
        Status,
        Protection
    };

    MQ2WebUpdateFileType()
        : MQ2Type("WebUpdateFile")
    {
        TypeMember(Name);
        TypeMember(RepoPath);
        TypeMember(Status);
        TypeMember(Protection);
    }

    bool GetMember(
        MQVarPtr VarPtr,
        const char* Member,
        char* Index,
        MQTypeVar& Dest) override
    {
        MQTypeMember* pMember =
            MQ2WebUpdateFileType::FindMember(
                Member
            );

        if (!pMember)
            return false;

        const size_t fileIndex =
            static_cast<size_t>(
                VarPtr.DWord
            );

        if (fileIndex == 0 ||
            fileIndex >
                g_fileResults.size())
        {
            return false;
        }

        const FileResult& result =
            g_fileResults[fileIndex - 1];

        switch ((Members)pMember->ID)
        {
        case Name:
            return SetString(
                Dest,
                result.fileName
            );

        case RepoPath:
            return SetString(
                Dest,
                result.repoPath
            );

        case Status:
            return SetString(
                Dest,
                result.status
            );

        case Protection:
            return SetString(
                Dest,
                result.protection
            );
        }

        return false;
    }

    bool ToString(
        MQVarPtr VarPtr,
        char* Destination) override
    {
        const size_t fileIndex =
            static_cast<size_t>(
                VarPtr.DWord
            );

        if (fileIndex == 0 ||
            fileIndex >
                g_fileResults.size())
        {
            strcpy_s(
                Destination,
                MAX_STRING,
                "NULL"
            );

            return false;
        }

        strcpy_s(
            Destination,
            MAX_STRING,
            g_fileResults[fileIndex - 1]
                .fileName.c_str()
        );

        return true;
    }

private:
    bool SetString(
        MQTypeVar& Dest,
        const std::string& value)
    {
        strcpy_s(
            m_buffer,
            sizeof(m_buffer),
            value.c_str()
        );

        Dest.Ptr =
            m_buffer;

        Dest.Type =
            mq::datatypes::pStringType;

        return true;
    }

    char m_buffer[MAX_STRING] = {};
};


class MQ2WebUpdateType : public MQ2Type
{
public:
    enum Members
    {
        Status = 1,
        RemoteSHA,
        Repository,
        Branch,
        LastError,
        FileCount,
        SameCount,
        UpdateCount,
        MissingCount,
        ProtectedCount,
        ErrorCount,
        UpdateAvailable,
        File
    };

    MQ2WebUpdateType()
        : MQ2Type("WebUpdate")
    {
        TypeMember(Status);
        TypeMember(RemoteSHA);
        TypeMember(Repository);
        TypeMember(Branch);
        TypeMember(LastError);

        TypeMember(FileCount);
        TypeMember(SameCount);
        TypeMember(UpdateCount);
        TypeMember(MissingCount);
        TypeMember(ProtectedCount);
        TypeMember(ErrorCount);

        TypeMember(UpdateAvailable);
        TypeMember(File);
    }

    bool GetMember(
        MQVarPtr VarPtr,
        const char* Member,
        char* Index,
        MQTypeVar& Dest) override
    {
        MQTypeMember* pMember =
            MQ2WebUpdateType::FindMember(
                Member
            );

        if (!pMember)
            return false;

        switch ((Members)pMember->ID)
        {
        case Status:
            return SetString(
                Dest,
                g_status
            );

        case RemoteSHA:
            return SetString(
                Dest,
                g_remoteSha
            );

        case Repository:
            return SetString(
                Dest,
                std::string(kOwner) +
                "/" +
                kRepo
            );

        case Branch:
            return SetString(
                Dest,
                kBranch
            );

        case LastError:
            return SetString(
                Dest,
                g_lastError
            );

        case FileCount:
            Dest.DWord =
                static_cast<DWORD>(
                    g_fileResults.size()
                );

            Dest.Type =
                mq::datatypes::pIntType;

            return true;

        case SameCount:
            Dest.DWord =
                static_cast<DWORD>(
                    g_sameCount
                );

            Dest.Type =
                mq::datatypes::pIntType;

            return true;

        case UpdateCount:
            Dest.DWord =
                static_cast<DWORD>(
                    g_updateCount
                );

            Dest.Type =
                mq::datatypes::pIntType;

            return true;

        case MissingCount:
            Dest.DWord =
                static_cast<DWORD>(
                    g_missingCount
                );

            Dest.Type =
                mq::datatypes::pIntType;

            return true;

        case ProtectedCount:
            Dest.DWord =
                static_cast<DWORD>(
                    g_protectedCount
                );

            Dest.Type =
                mq::datatypes::pIntType;

            return true;

        case ErrorCount:
            Dest.DWord =
                static_cast<DWORD>(
                    g_errorCount
                );

            Dest.Type =
                mq::datatypes::pIntType;

            return true;

        case UpdateAvailable:
            Dest.DWord =
                (g_updateCount > 0 ||
                 g_missingCount > 0)
                    ? 1
                    : 0;

            Dest.Type =
                mq::datatypes::pBoolType;

            return true;

        case File:
        {
            if (!Index ||
                !Index[0])
            {
                return false;
            }

            const int requested =
                atoi(Index);

            if (requested <= 0 ||
                static_cast<size_t>(
                    requested
                ) >
                    g_fileResults.size())
            {
                return false;
            }

            Dest.DWord =
                static_cast<DWORD>(
                    requested
                );

            Dest.Type =
                pWebUpdateFileType;

            return true;
        }
        }

        return false;
    }

    bool ToString(
        MQVarPtr VarPtr,
        char* Destination) override
    {
        strcpy_s(
            Destination,
            MAX_STRING,
            g_status.c_str()
        );

        return true;
    }

private:
    bool SetString(
        MQTypeVar& Dest,
        const std::string& value)
    {
        strcpy_s(
            m_buffer,
            sizeof(m_buffer),
            value.c_str()
        );

        Dest.Ptr =
            m_buffer;

        Dest.Type =
            mq::datatypes::pStringType;

        return true;
    }

    char m_buffer[MAX_STRING] = {};
};


bool dataWebUpdate(
    const char* Index,
    MQTypeVar& Dest)
{
    Dest.DWord = 1;
    Dest.Type = pWebUpdateType;

    return true;
}

void ShowStatus()
    {
        WriteChatf(
            "\ay[MQ2WebUpdate]\ax Status: %s",
            g_status.c_str()
        );

        if (!g_remoteSha.empty())
        {
            WriteChatf(
                "\ay[MQ2WebUpdate]\ax Remote SHA: %s",
                g_remoteSha.c_str()
            );
        }

        if (!g_remoteFiles.empty())
        {
            WriteChatf(
                "\ay[MQ2WebUpdate]\ax Discovered Lua files: %zu",
                g_remoteFiles.size()
            );
        }

        if (!g_lastError.empty())
        {
            WriteChatf(
                "\ar[MQ2WebUpdate]\ax Last Error: %s",
                g_lastError.c_str()
            );
        }
    }

    void ShowHelp()
    {
        WriteChatf(
            "\ay[MQ2WebUpdate]\ax Commands:"
        );

        WriteChatf(
            "\at/webupdate check\ax   - Check GitHub branch SHA"
        );

        WriteChatf(
            "\at/webupdate scan\ax    - Discover TAC/lua files"
        );

        WriteChatf(
            "\at/webupdate compare\ax - Compare GitHub files to local MQ2 Lua"
        );

        WriteChatf(
            "\at/webupdate stage\ax   - Download changed files into safe staging"
        );

        WriteChatf(
            "\at/webupdate update\ax  - Start safe asynchronous update staging"
        );

        WriteChatf(
            "\at/webupdate apply\ax   - Apply an already staged transaction"
        );

        WriteChatf(
            "\at/webupdate protect\ax - Show protected/reparse Lua files"
        );

        WriteChatf(
            "\at/webupdate status\ax  - Show updater status"
        );

        WriteChatf(
            "\at/webupdate help\ax    - Show this help"
        );

        WriteChatf(
            "\ay[MQ2WebUpdate]\ax For automatic stop, apply, and restart, use Triune's Update & Restart button."
        );
    }
    bool WorkerCheckResponse(
        const cpr::Response& response,
        std::string& error)
    {
        if (response.error)
        {
            error = response.error.message;
            return false;
        }

        if (response.status_code != 200)
        {
            error =
                "GitHub returned HTTP " +
                std::to_string(response.status_code);

            return false;
        }

        return true;
    }

    std::string WorkerRawGitHubUrl(
        const std::string& remoteSha,
        const std::string& repoPath)
    {
        return
            std::string("https://raw.githubusercontent.com/") +
            kOwner + "/" +
            kRepo + "/" +
            remoteSha + "/" +
            repoPath;
    }

    CompareWorkerResult RunCompareWorker()
    {
        CompareWorkerResult output;
        output.status = "Compare Error";

        // --------------------------------------------------------
        // 1. Resolve the exact remote commit.
        // --------------------------------------------------------

        const std::string commitUrl =
            std::string("https://api.github.com/repos/") +
            kOwner + "/" + kRepo +
            "/commits/" + kBranch;

        auto commitResponse = GitHubGet(commitUrl);

        if (!WorkerCheckResponse(
                commitResponse,
                output.lastError))
        {
            ++output.errorCount;
            return output;
        }

        output.remoteSha =
            ExtractJsonString(
                commitResponse.text,
                "sha"
            );

        if (output.remoteSha.empty())
        {
            output.lastError =
                "Could not parse commit SHA.";

            ++output.errorCount;
            return output;
        }

        // --------------------------------------------------------
        // 2. Discover TAC/lua recursively from that exact SHA.
        // --------------------------------------------------------

        const std::string treeUrl =
            std::string("https://api.github.com/repos/") +
            kOwner + "/" + kRepo +
            "/git/trees/" + output.remoteSha +
            "?recursive=1";

        auto treeResponse = GitHubGet(treeUrl);

        if (!WorkerCheckResponse(
                treeResponse,
                output.lastError))
        {
            ++output.errorCount;
            return output;
        }

        const std::string pathNeedle = "\"path\"";
        size_t pos = 0;

        while (true)
        {
            pos =
                treeResponse.text.find(
                    pathNeedle,
                    pos
                );

            if (pos == std::string::npos)
                break;

            auto colonPos =
                treeResponse.text.find(
                    ':',
                    pos + pathNeedle.size()
                );

            if (colonPos == std::string::npos)
                break;

            auto firstQuote =
                treeResponse.text.find(
                    '"',
                    colonPos + 1
                );

            if (firstQuote == std::string::npos)
                break;

            auto secondQuote =
                treeResponse.text.find(
                    '"',
                    firstQuote + 1
                );

            if (secondQuote == std::string::npos)
                break;

            std::string path =
                treeResponse.text.substr(
                    firstQuote + 1,
                    secondQuote - firstQuote - 1
                );

            if (path.rfind(kLuaPrefix, 0) == 0)
            {
                std::string relative =
                    path.substr(
                        std::string(kLuaPrefix).size()
                    );

                if (!relative.empty() &&
                    relative.back() != '/')
                {
                    RemoteFile file;
                    file.repoPath = path;
                    file.fileName = relative;

                    output.remoteFiles.push_back(
                        std::move(file)
                    );
                }
            }

            pos = secondQuote + 1;
        }

        std::sort(
            output.remoteFiles.begin(),
            output.remoteFiles.end(),
            [](const RemoteFile& a,
               const RemoteFile& b)
            {
                return a.repoPath < b.repoPath;
            }
        );

        output.remoteFiles.erase(
            std::unique(
                output.remoteFiles.begin(),
                output.remoteFiles.end(),
                [](const RemoteFile& a,
                   const RemoteFile& b)
                {
                    return
                        a.repoPath ==
                        b.repoPath;
                }
            ),
            output.remoteFiles.end()
        );

        if (output.remoteFiles.empty())
        {
            output.lastError =
                "No files found under TAC/lua/.";

            ++output.errorCount;
            return output;
        }

        // --------------------------------------------------------
        // 3. Locate the runtime Lua directory.
        //
        // This is filesystem/Win32 work only. No MQ APIs/TLOs.
        // --------------------------------------------------------

        fs::path luaDirectory =
            GetRuntimeLuaDirectory();

        if (luaDirectory.empty())
        {
            output.lastError =
                "Could not locate MQ2 runtime Lua directory.";

            ++output.errorCount;
            return output;
        }

        output.runtimeLuaDirectory =
            luaDirectory.string();

        // --------------------------------------------------------
        // 4. Download and compare every discovered Lua file.
        //
        // IMPORTANT:
        // Everything here belongs only to 'output'. We do NOT
        // modify the WebUpdate TLO globals from this thread.
        // --------------------------------------------------------

        for (const auto& remote : output.remoteFiles)
        {
            FileResult result;
            result.fileName = remote.fileName;
            result.repoPath = remote.repoPath;
            result.status = "UNKNOWN";
            result.protection = "UNKNOWN";

            fs::path localPath =
                luaDirectory / remote.fileName;

            std::error_code ec;

            const bool exists =
                fs::exists(localPath, ec);

            if (ec)
            {
                ++output.errorCount;

                result.status = "ERROR";
                result.protection = "UNKNOWN";

                output.fileResults.push_back(
                    std::move(result)
                );

                continue;
            }

            auto response =
                GitHubGet(
                    WorkerRawGitHubUrl(
                        output.remoteSha,
                        remote.repoPath
                    )
                );

            std::string requestError;

            if (!WorkerCheckResponse(
                    response,
                    requestError))
            {
                ++output.errorCount;

                result.status = "ERROR";

                if (output.lastError.empty())
                    output.lastError = requestError;

                if (exists &&
                    IsReparsePoint(localPath))
                {
                    result.protection =
                        "LINK PROTECTED";

                    ++output.protectedCount;
                }
                else if (exists)
                {
                    result.protection =
                        "REGULAR";
                }
                else
                {
                    result.protection =
                        "NEW FILE";
                }

                output.fileResults.push_back(
                    std::move(result)
                );

                continue;
            }

            if (!exists)
            {
                ++output.missingCount;

                result.status = "MISSING";
                result.protection = "NEW FILE";

                output.fileResults.push_back(
                    std::move(result)
                );

                continue;
            }

            if (IsReparsePoint(localPath))
            {
                result.protection =
                    "LINK PROTECTED";

                ++output.protectedCount;
            }
            else
            {
                result.protection =
                    "REGULAR";
            }

            std::string localData;

            if (!ReadFileBinary(
                    localPath,
                    localData))
            {
                ++output.errorCount;

                result.status = "ERROR";

                output.fileResults.push_back(
                    std::move(result)
                );

                continue;
            }

            if (NormalizeTextLineEndings(localData) ==
                NormalizeTextLineEndings(response.text))
            {
                ++output.sameCount;
                result.status = "SAME";
            }
            else
            {
                ++output.updateCount;
                result.status = "UPDATE";
            }

            output.fileResults.push_back(
                std::move(result)
            );
        }

        // --------------------------------------------------------
        // 5. Determine final state.
        // --------------------------------------------------------

        if (output.errorCount > 0)
        {
            output.status = "Compare Error";

            if (output.lastError.empty())
            {
                output.lastError =
                    "One or more files could not be compared.";
            }

            output.success = false;
        }
        else if (
            output.updateCount > 0 ||
            output.missingCount > 0)
        {
            output.status = "Update Available";
            output.success = true;
        }
        else
        {
            output.status = "Up To Date";
            output.success = true;
        }

        return output;
    }

    CompareWorkerResult RunStageWorker()
    {
        CompareWorkerResult output;
        output.operation = "stage";
        output.status = "Stage Error";

        // --------------------------------------------------------
        // 1. Resolve exact remote SHA.
        // --------------------------------------------------------

        const std::string commitUrl =
            std::string("https://api.github.com/repos/") +
            kOwner + "/" + kRepo +
            "/commits/" + kBranch;

        auto commitResponse = GitHubGet(commitUrl);

        if (!WorkerCheckResponse(
                commitResponse,
                output.lastError))
        {
            ++output.errorCount;
            return output;
        }

        output.remoteSha =
            ExtractJsonString(
                commitResponse.text,
                "sha"
            );

        if (!IsValidGitSha(output.remoteSha))
        {
            output.lastError =
                "Remote commit SHA is invalid.";

            ++output.errorCount;
            return output;
        }

        // --------------------------------------------------------
        // 2. Discover TAC/lua files at that exact SHA.
        // --------------------------------------------------------

        const std::string treeUrl =
            std::string("https://api.github.com/repos/") +
            kOwner + "/" + kRepo +
            "/git/trees/" + output.remoteSha +
            "?recursive=1";

        auto treeResponse = GitHubGet(treeUrl);

        if (!WorkerCheckResponse(
                treeResponse,
                output.lastError))
        {
            ++output.errorCount;
            return output;
        }

        const std::string pathNeedle = "\"path\"";
        size_t pos = 0;

        while (true)
        {
            pos =
                treeResponse.text.find(
                    pathNeedle,
                    pos
                );

            if (pos == std::string::npos)
                break;

            auto colonPos =
                treeResponse.text.find(
                    ':',
                    pos + pathNeedle.size()
                );

            if (colonPos == std::string::npos)
                break;

            auto firstQuote =
                treeResponse.text.find(
                    '"',
                    colonPos + 1
                );

            if (firstQuote == std::string::npos)
                break;

            auto secondQuote =
                treeResponse.text.find(
                    '"',
                    firstQuote + 1
                );

            if (secondQuote == std::string::npos)
                break;

            std::string path =
                treeResponse.text.substr(
                    firstQuote + 1,
                    secondQuote - firstQuote - 1
                );

            if (path.rfind(kLuaPrefix, 0) == 0)
            {
                std::string relative =
                    path.substr(
                        std::string(kLuaPrefix).size()
                    );

                if (!relative.empty() &&
                    relative.back() != '/')
                {
                    RemoteFile remote;
                    remote.repoPath = path;
                    remote.fileName = relative;

                    output.remoteFiles.push_back(
                        std::move(remote)
                    );
                }
            }

            pos = secondQuote + 1;
        }

        std::sort(
            output.remoteFiles.begin(),
            output.remoteFiles.end(),
            [](const RemoteFile& a,
               const RemoteFile& b)
            {
                return a.repoPath < b.repoPath;
            }
        );

        output.remoteFiles.erase(
            std::unique(
                output.remoteFiles.begin(),
                output.remoteFiles.end(),
                [](const RemoteFile& a,
                   const RemoteFile& b)
                {
                    return a.repoPath == b.repoPath;
                }
            ),
            output.remoteFiles.end()
        );

        if (output.remoteFiles.empty())
        {
            output.lastError =
                "No files found under TAC/lua/.";

            ++output.errorCount;
            return output;
        }

        // --------------------------------------------------------
        // 3. Build fresh SHA-specific staging transaction.
        // --------------------------------------------------------

        fs::path luaDirectory =
            GetRuntimeLuaDirectory();

        if (luaDirectory.empty())
        {
            output.lastError =
                "Could not locate MQ2 runtime Lua directory.";

            ++output.errorCount;
            return output;
        }

        output.runtimeLuaDirectory =
            luaDirectory.string();

        fs::path runtimeRoot =
            luaDirectory.parent_path();

        fs::path stageRoot =
            runtimeRoot /
            "webupdate_stage" /
            "TriuneAutocombat";

        std::error_code stageEc;

        fs::remove_all(
            stageRoot,
            stageEc
        );

        if (stageEc)
        {
            output.lastError =
                "Could not clear previous staging transaction.";

            ++output.errorCount;
            return output;
        }

        fs::path stageDirectory =
            stageRoot /
            output.remoteSha;

        fs::create_directories(
            stageDirectory,
            stageEc
        );

        if (stageEc)
        {
            output.lastError =
                "Could not create SHA staging directory.";

            ++output.errorCount;
            return output;
        }

        output.stageDirectory =
            stageDirectory.string();

        // --------------------------------------------------------
        // 4. Download each file ONCE.
        //
        // Same payload is used for comparison and staging.
        // --------------------------------------------------------

        for (const auto& remote : output.remoteFiles)
        {
            FileResult result;
            result.fileName = remote.fileName;
            result.repoPath = remote.repoPath;
            result.status = "UNKNOWN";
            result.protection = "UNKNOWN";

            fs::path localPath =
                luaDirectory /
                remote.fileName;

            fs::path stagePath =
                stageDirectory /
                remote.fileName;

            std::error_code ec;

            const bool localExists =
                fs::exists(localPath, ec);

            if (ec)
            {
                ++output.errorCount;
                result.status = "ERROR";

                output.fileResults.push_back(
                    std::move(result)
                );

                continue;
            }

            const bool localProtected =
                localExists &&
                IsReparsePoint(localPath);

            if (localProtected)
            {
                result.protection =
                    "LINK PROTECTED";

                ++output.protectedCount;
            }
            else if (localExists)
            {
                result.protection =
                    "REGULAR";
            }
            else
            {
                result.protection =
                    "NEW FILE";
            }

            auto response =
                GitHubGet(
                    WorkerRawGitHubUrl(
                        output.remoteSha,
                        remote.repoPath
                    )
                );

            std::string requestError;

            if (!WorkerCheckResponse(
                    response,
                    requestError))
            {
                ++output.errorCount;
                result.status = "ERROR";

                if (output.lastError.empty())
                    output.lastError = requestError;

                output.fileResults.push_back(
                    std::move(result)
                );

                continue;
            }

            if (localExists)
            {
                std::string localData;

                if (!ReadFileBinary(
                        localPath,
                        localData))
                {
                    ++output.errorCount;
                    result.status = "ERROR";

                    if (output.lastError.empty())
                    {
                        output.lastError =
                            "Could not read local file: " +
                            remote.fileName;
                    }

                    output.fileResults.push_back(
                        std::move(result)
                    );

                    continue;
                }

                if (NormalizeTextLineEndings(localData) ==
                    NormalizeTextLineEndings(response.text))
                {
                    ++output.sameCount;
                    result.status = "SAME";

                    output.fileResults.push_back(
                        std::move(result)
                    );

                    continue;
                }

                ++output.updateCount;
                result.status = "UPDATE";
            }
            else
            {
                ++output.missingCount;
                result.status = "MISSING";
            }

            // Changed/missing file: stage the exact downloaded
            // bytes, but NEVER modify the live Lua here.
            if (!WriteFileBinary(
                    stagePath,
                    response.text))
            {
                ++output.errorCount;
                result.status = "ERROR";

                if (output.lastError.empty())
                {
                    output.lastError =
                        "Could not write staged file: " +
                        remote.fileName;
                }

                output.fileResults.push_back(
                    std::move(result)
                );

                continue;
            }

            std::string verifyData;

            if (!ReadFileBinary(
                    stagePath,
                    verifyData) ||
                verifyData != response.text)
            {
                ++output.errorCount;
                result.status = "ERROR";

                if (output.lastError.empty())
                {
                    output.lastError =
                        "Stage verification failed: " +
                        remote.fileName;
                }

                output.fileResults.push_back(
                    std::move(result)
                );

                continue;
            }

            if (localExists)
                ++output.stagedUpdateCount;
            else
                ++output.stagedMissingCount;

            output.fileResults.push_back(
                std::move(result)
            );
        }

        // --------------------------------------------------------
        // 5. stage.ini is the transaction commit marker.
        //    NEVER write it if anything failed.
        // --------------------------------------------------------

        if (output.errorCount > 0)
        {
            output.status = "Stage Error";

            if (output.lastError.empty())
            {
                output.lastError =
                    "Staging did not complete successfully. "
                    "No stage metadata was committed.";
            }

            output.success = false;
            return output;
        }

        fs::path metadataPath =
            stageRoot /
            "stage.ini";

        if (!WriteStageMetadata(
                metadataPath,
                output.remoteSha))
        {
            ++output.errorCount;

            output.status = "Stage Error";
            output.lastError =
                "Staging completed, but stage metadata "
                "could not be committed.";

            output.success = false;
            return output;
        }

        if (output.stagedUpdateCount > 0 ||
            output.stagedMissingCount > 0)
        {
            output.status = "Staged";
        }
        else
        {
            output.status = "Up To Date";
        }

        output.success = true;
        return output;
    }
    void CompareWorkerMain()
    {
        CompareWorkerResult result;

        try
        {
            result = RunCompareWorker();
        }
        catch (const std::exception& ex)
        {
            result.success = false;
            result.status = "Compare Error";
            result.lastError =
                std::string(
                    "Compare worker exception: "
                ) + ex.what();

            ++result.errorCount;
        }
        catch (...)
        {
            result.success = false;
            result.status = "Compare Error";
            result.lastError =
                "Unknown compare worker exception.";

            ++result.errorCount;
        }

        {
            std::lock_guard<std::mutex> lock(
                g_compareMutex
            );

            g_compareCompletedResult =
                std::move(result);

            g_compareResultReady = true;
        }

        g_compareRunning.store(false);
    }

    void StageWorkerMain()
    {
        CompareWorkerResult result;

        try
        {
            result = RunStageWorker();
        }
        catch (const std::exception& ex)
        {
            result.operation = "stage";
            result.success = false;
            result.status = "Stage Error";
            result.lastError =
                std::string(
                    "Stage worker exception: "
                ) + ex.what();

            ++result.errorCount;
        }
        catch (...)
        {
            result.operation = "stage";
            result.success = false;
            result.status = "Stage Error";
            result.lastError =
                "Unknown stage worker exception.";

            ++result.errorCount;
        }

        {
            std::lock_guard<std::mutex> lock(
                g_compareMutex
            );

            g_compareCompletedResult =
                std::move(result);

            g_compareResultReady = true;
        }

        g_compareRunning.store(false);
    }

    bool StartAsyncStage()
    {
        if (g_compareRunning.load())
        {
            WriteChatf(
                "\ay[MQ2WebUpdate]\ax A web update operation is already running."
            );

            return false;
        }

        if (g_compareThread.joinable())
        {
            g_compareThread.join();
        }

        {
            std::lock_guard<std::mutex> lock(
                g_compareMutex
            );

            g_compareResultReady = false;
            g_compareCompletedResult =
                CompareWorkerResult{};
        }

        g_status = "Staging";
        g_lastError.clear();

        g_compareRunning.store(true);

        try
        {
            g_compareThread =
                std::thread(StageWorkerMain);
        }
        catch (const std::exception& ex)
        {
            g_compareRunning.store(false);

            g_status = "Stage Error";
            g_lastError =
                std::string(
                    "Could not start stage worker: "
                ) + ex.what();

            WriteChatf(
                "\ar[MQ2WebUpdate]\ax %s",
                g_lastError.c_str()
            );

            return false;
        }
        catch (...)
        {
            g_compareRunning.store(false);

            g_status = "Stage Error";
            g_lastError =
                "Could not start stage worker.";

            WriteChatf(
                "\ar[MQ2WebUpdate]\ax %s",
                g_lastError.c_str()
            );

            return false;
        }

        WriteChatf(
            "\ag[MQ2WebUpdate]\ax Update staging started in background."
        );

        return true;
    }
    bool StartAsyncCompare()
    {
        if (g_compareRunning.load())
        {
            WriteChatf(
                "\ay[MQ2WebUpdate]\ax A comparison is already running."
            );

            return false;
        }

        // A previous worker may have completed and already been
        // published by OnPulse. Reclaim its std::thread object
        // before starting another one.
        if (g_compareThread.joinable())
        {
            g_compareThread.join();
        }

        {
            std::lock_guard<std::mutex> lock(
                g_compareMutex
            );

            g_compareResultReady = false;
            g_compareCompletedResult =
                CompareWorkerResult{};
        }

        // Publish only the lightweight "working" state here on the
        // MacroQuest thread. The worker owns everything else until
        // it completes.
        g_status = "Comparing";
        g_lastError.clear();

        g_compareRunning.store(true);

        try
        {
            g_compareThread =
                std::thread(CompareWorkerMain);
        }
        catch (const std::exception& ex)
        {
            g_compareRunning.store(false);

            g_status = "Compare Error";
            g_lastError =
                std::string(
                    "Could not start compare worker: "
                ) + ex.what();

            WriteChatf(
                "\ar[MQ2WebUpdate]\ax %s",
                g_lastError.c_str()
            );

            return false;
        }
        catch (...)
        {
            g_compareRunning.store(false);

            g_status = "Compare Error";
            g_lastError =
                "Could not start compare worker.";

            WriteChatf(
                "\ar[MQ2WebUpdate]\ax %s",
                g_lastError.c_str()
            );

            return false;
        }

        WriteChatf(
            "\ag[MQ2WebUpdate]\ax GitHub comparison started in background."
        );

        return true;
    }

    void PublishAsyncCompareResult()
    {
        CompareWorkerResult result;

        {
            std::lock_guard<std::mutex> lock(
                g_compareMutex
            );

            if (!g_compareResultReady)
                return;

            result =
                std::move(
                    g_compareCompletedResult
                );

            g_compareCompletedResult =
                CompareWorkerResult{};

            g_compareResultReady = false;
        }

        // We are back on MacroQuest's main thread here.
        g_remoteSha =
            std::move(result.remoteSha);

        g_remoteFiles =
            std::move(result.remoteFiles);

        g_fileResults =
            std::move(result.fileResults);

        g_sameCount =
            result.sameCount;

        g_updateCount =
            result.updateCount;

        g_missingCount =
            result.missingCount;

        g_protectedCount =
            result.protectedCount;

        g_errorCount =
            result.errorCount;

        g_lastError =
            std::move(result.lastError);

        g_status =
            result.status.empty()
                ? "Compare Error"
                : std::move(result.status);

        WriteChatf(
            "\ay[MQ2WebUpdate]\ax ------------------------------"
        );

        if (!result.runtimeLuaDirectory.empty())
        {
            WriteChatf(
                "\ay[MQ2WebUpdate]\ax Runtime Lua folder:"
            );

            WriteChatf(
                "\at[MQ2WebUpdate]\ax %s",
                result.runtimeLuaDirectory.c_str()
            );
        }

        if (!g_remoteSha.empty())
        {
            WriteChatf(
                "\ay[MQ2WebUpdate]\ax Comparing against commit:"
            );

            WriteChatf(
                "\at[MQ2WebUpdate]\ax %s",
                g_remoteSha.c_str()
            );
        }

        for (const auto& file : g_fileResults)
        {
            if (file.status == "SAME")
            {
                WriteChatf(
                    "\ag[MQ2WebUpdate]\ax SAME    %s",
                    file.fileName.c_str()
                );
            }
            else if (file.status == "UPDATE")
            {
                WriteChatf(
                    "\ao[MQ2WebUpdate]\ax UPDATE  %s",
                    file.fileName.c_str()
                );
            }
            else if (file.status == "MISSING")
            {
                WriteChatf(
                    "\ay[MQ2WebUpdate]\ax MISSING %s",
                    file.fileName.c_str()
                );
            }
            else
            {
                WriteChatf(
                    "\ar[MQ2WebUpdate]\ax ERROR   %s",
                    file.fileName.c_str()
                );
            }
        }

        WriteChatf(
            "\ay[MQ2WebUpdate]\ax ------------------------------"
        );

        WriteChatf(
            "\ay[MQ2WebUpdate]\ax Remote files: %zu",
            g_remoteFiles.size()
        );

        WriteChatf(
            "\ag[MQ2WebUpdate]\ax Same: %zu",
            g_sameCount
        );

        WriteChatf(
            "\ao[MQ2WebUpdate]\ax Update: %zu",
            g_updateCount
        );

        WriteChatf(
            "\ay[MQ2WebUpdate]\ax Missing: %zu",
            g_missingCount
        );

        WriteChatf(
            "\ao[MQ2WebUpdate]\ax Protected links: %zu",
            g_protectedCount
        );

        WriteChatf(
            "\ar[MQ2WebUpdate]\ax Errors: %zu",
            g_errorCount
        );

        if (!g_lastError.empty())
        {
            WriteChatf(
                "\ar[MQ2WebUpdate]\ax Last Error: %s",
                g_lastError.c_str()
            );
        }

        if (result.operation == "stage")
        {
            WriteChatf(
                "\ay[MQ2WebUpdate]\ax ------------------------------"
            );

            if (!result.stageDirectory.empty())
            {
                WriteChatf(
                    "\ay[MQ2WebUpdate]\ax Stage folder: %s",
                    result.stageDirectory.c_str()
                );
            }

            WriteChatf(
                "\ag[MQ2WebUpdate]\ax Same / skipped: %zu",
                result.sameCount
            );

            WriteChatf(
                "\ao[MQ2WebUpdate]\ax Updates staged: %zu",
                result.stagedUpdateCount
            );

            WriteChatf(
                "\ay[MQ2WebUpdate]\ax Missing staged: %zu",
                result.stagedMissingCount
            );

            WriteChatf(
                "\ao[MQ2WebUpdate]\ax Protected live links seen: %zu",
                result.protectedCount
            );

            WriteChatf(
                "\ag[MQ2WebUpdate]\ax Live files changed: 0"
            );

            if (result.success)
            {
                WriteChatf(
                    "\ag[MQ2WebUpdate]\ax Stage transaction committed."
                );

                WriteChatf(
                    "\ag[MQ2WebUpdate]\ax Stage complete. Live Lua files were not changed."
                );
            }
            else
            {
                WriteChatf(
                    "\ar[MQ2WebUpdate]\ax Stage incomplete. Apply is not permitted."
                );
            }

            return;
        }

        WriteChatf(
            "\ag[MQ2WebUpdate]\ax Compare complete. No files changed."
        );
    }
    std::string NormalizeCommand(
        std::string command)
    {
        while (!command.empty() &&
               std::isspace(
                   static_cast<unsigned char>(
                       command.front())))
        {
            command.erase(command.begin());
        }

        while (!command.empty() &&
               std::isspace(
                   static_cast<unsigned char>(
                       command.back())))
        {
            command.pop_back();
        }

        std::transform(
            command.begin(),
            command.end(),
            command.begin(),
            [](unsigned char c)
            {
                return static_cast<char>(
                    std::tolower(c)
                );
            }
        );

        return command;
    }
}

void WebUpdateCmd(
    PSPAWNINFO pChar,
    PCHAR szLine)
{
    std::string command =
        NormalizeCommand(
            szLine ? szLine : ""
        );

    if (command.empty() ||
        command == "help")
    {
        ShowHelp();
        return;
    }

    if (command == "check")
    {
        WriteChatf(
            "\ag[MQ2WebUpdate]\ax Checking GitHub for latest commit..."
        );

        CheckRemoteSha(true);
        return;
    }

    if (command == "scan")
    {
        WriteChatf(
            "\ag[MQ2WebUpdate]\ax Scanning GitHub repository..."
        );

        ScanRemoteLuaFiles(true);
        return;
    }

    if (command == "compare")
    {
        WriteChatf(
            "\ag[MQ2WebUpdate]\ax Comparing GitHub with local MQ2 Lua files..."
        );

        StartAsyncCompare();
        return;
    }

    if (command == "apply")
    {
        ApplyStagedLuaFiles();
        return;
    }

    if (command == "stage")
    {
        WriteChatf(
            "\ag[MQ2WebUpdate]\ax Preparing update staging area..."
        );

        StartAsyncStage();
        return;
    }

    if (command == "update")
    {
        WriteChatf(
            "\ag[MQ2WebUpdate]\ax Starting safe asynchronous update staging..."
        );

        WriteChatf(
            "\ay[MQ2WebUpdate]\ax Use Triune's Update & Restart button for automatic stop/apply/restart."
        );

        StartAsyncStage();
        return;
    }

    if (command == "protect")
    {
        ShowProtection();
        return;
    }

    if (command == "status")
    {
        ShowStatus();
        return;
    }

    WriteChatf(
        "\ar[MQ2WebUpdate]\ax Unknown command: %s",
        command.c_str()
    );

    ShowHelp();
}

PLUGIN_API void OnPulse()
{
    PublishAsyncCompareResult();
}
PLUGIN_API void InitializePlugin()
{
    pWebUpdateFileType =
        new MQ2WebUpdateFileType();

    pWebUpdateType =
        new MQ2WebUpdateType();

    AddMQ2Data(
        "WebUpdate",
        dataWebUpdate
    );
    DebugSpewAlways(
        "Initializing MQ2WebUpdate"
    );

    AddCommand(
        "/webupdate",
        WebUpdateCmd
    );

    WriteChatf(
        "\ag[MQ2WebUpdate]\ax Loaded. Use /webupdate help."
    );
}

PLUGIN_API void ShutdownPlugin()
{
    // Never allow the plugin DLL to unload while its background
    // compare worker is still executing code from this module.
    if (g_compareThread.joinable())
    {
        g_compareThread.join();
    }

    g_compareRunning.store(false);

    {
        std::lock_guard<std::mutex> lock(
            g_compareMutex
        );

        g_compareResultReady = false;
        g_compareCompletedResult =
            CompareWorkerResult{};
    }

    RemoveMQ2Data(
        "WebUpdate"
    );

    delete pWebUpdateType;
    pWebUpdateType = nullptr;

    delete pWebUpdateFileType;
    pWebUpdateFileType = nullptr;
    RemoveCommand(
        "/webupdate"
    );

    DebugSpewAlways(
        "Shutting down MQ2WebUpdate"
    );
}



















