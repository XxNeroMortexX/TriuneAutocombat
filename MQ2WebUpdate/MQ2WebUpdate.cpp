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
#include <iterator>
#include <thread>
#include <mutex>
#include <atomic>
#include <openssl/sha.h>

#include "MQ2WebUpdateProfiles.h"
#include "MQ2WebUpdateProfileStore.h"
#include "MQ2WebUpdateCredentials.h"
#include "MQ2WebUpdatePlanner.h"
#include "MQ2WebUpdateProviders.h"
#include "MQ2WebUpdateStagePlan.h"

PreSetup("MQ2WebUpdate");

namespace
{
    namespace fs = std::filesystem;
    namespace profilemodel = mq2webupdate::profiles;

    struct RemoteFile
    {
        std::string repoPath;
        std::string fileName;
        std::string mappingId;
        std::string mappingRelativePath;
        std::string stageRelativePath;
        profilemodel::DestinationRoot destinationRoot =
            profilemodel::DestinationRoot::Lua;
        std::string destinationRelativePath;
        std::uint64_t expectedSize = 0;
        std::string gitObjectSha;
        bool restartRequired = false;
    };
struct FileResult
{
    std::string fileName;
    std::string repoPath;

    // Created by: NeroMorte - Expose read-only update-plan path and per-file diagnostic details.
    std::string sourcePath;
    std::string destinationPath;
    std::string error;
    std::string mappingId;
    std::string mappingRelativePath;

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
    std::vector<mq2webupdate::planner::BrowserEntry> repositoryTree;

    size_t sameCount = 0;
    size_t updateCount = 0;
    size_t missingCount = 0;
    size_t protectedCount = 0;
    size_t errorCount = 0;

    size_t stagedUpdateCount = 0;
    size_t stagedMissingCount = 0;
    bool restartRequired = false;

    std::string runtimeLuaDirectory;
    std::string stageDirectory;
};

std::thread g_compareThread;
std::mutex g_compareMutex;
std::atomic_bool g_compareRunning{ false };
bool g_compareResultReady = false;
CompareWorkerResult g_compareCompletedResult;
struct UpstreamWorkerResult
{
    bool success = false;
    std::string status = "Idle";
    std::string remoteSha;
    std::string lastError;
};

std::thread g_upstreamThread;
std::mutex g_upstreamMutex;
std::atomic_bool g_upstreamRunning{ false };
bool g_upstreamResultReady = false;
bool g_upstreamAnnounce = false;
UpstreamWorkerResult g_upstreamCompletedResult;

std::string g_upstreamStatus = "Idle";
std::string g_upstreamSha;
std::string g_upstreamLastError;

struct ManagedMonitorState
{
    std::string status = "Not Checked";
    std::string remoteSha;
    std::string lastError;
    std::string lastChecked;
};

// Created by: NeroMorte - retain an independent read-only comparison result
// for every configured repository. Main Download continues to own the only
// stage/apply pipeline; Monitor Only repositories expose comparison evidence
// without acquiring any mutation capability.
struct ManagedRepositoryView
{
    std::string status = "Not Checked";
    std::string remoteSha;
    std::string lastError;
    std::string lastChecked;
    std::vector<FileResult> fileResults;
    size_t sameCount = 0;
    size_t updateCount = 0;
    size_t missingCount = 0;
    size_t protectedCount = 0;
    size_t errorCount = 0;
};

struct ManagedMonitorWorkerResult
{
    std::map<std::string, ManagedMonitorState> states;
    std::map<std::string, ManagedRepositoryView> views;
};

std::thread g_monitorThread;
std::mutex g_monitorMutex;
std::atomic_bool g_monitorRunning{ false };
bool g_monitorResultReady = false;
ManagedMonitorWorkerResult g_monitorCompletedResult;
std::map<std::string, ManagedMonitorState> g_monitorStates;
std::map<std::string, std::chrono::steady_clock::time_point> g_monitorNextCheck;
std::map<std::string, ManagedRepositoryView> g_repositoryViews;
std::string g_compareProfileId;

// Created by: NeroMorte - Cache immutable recursive Git trees by repository
// and commit while the plugin remains loaded. A fresh branch-SHA request is
// still made for every check, but an unchanged repository needs no second API
// request and never downloads every remote file merely to compare it.
struct CachedRepositoryTree
{
    std::string commitSha;
    std::string json;
};

std::mutex g_repositoryTreeCacheMutex;
std::map<std::string, CachedRepositoryTree> g_repositoryTreeCache;

// Created by: NeroMorte - Serialize GitHub traffic from all updater workers.
// This prevents plugin-start and repository workers from producing concurrent
// bursts that can trigger GitHub's secondary abuse protection.
std::mutex g_githubRequestMutex;
std::chrono::steady_clock::time_point g_lastGitHubRequest;


    std::string g_status = "Idle";
    std::string g_remoteSha;
    std::string g_lastError;
    std::vector<RemoteFile> g_remoteFiles;
std::vector<FileResult> g_fileResults;
std::vector<mq2webupdate::planner::BrowserEntry> g_repositoryTree;

size_t g_sameCount = 0;
size_t g_updateCount = 0;
size_t g_missingCount = 0;
size_t g_protectedCount = 0;
size_t g_errorCount = 0;


// Created by: NeroMorte - MQ2WebUpdate 2.0 public engine/API state.
constexpr const char* kWebUpdateVersion = "4.1.1";
constexpr const char* kWebUpdateApiVersion = "4.0";
// Legacy defaults retained for migration of older settings files. The active
// main repository and every deployment mapping are loaded from the saved
// managed profile store for compare, stage, apply, and recovery.
constexpr const char* kDefaultProfileId = "morte";
constexpr const char* kDefaultSourceType = "github";
constexpr const char* kGlobalGitHubCredentialId = "global";

// Created by: NeroMorte - MQ2WebUpdate trusted profile definitions.
struct ProfileDefinition
{
    const char* id;
    const char* name;
    const char* sourceType;
    const char* owner;
    const char* repository;
    const char* branch;
};

constexpr ProfileDefinition kProfiles[] =
{
    {
        "morte",
        "NeroMorte",
        "github",
        "XxNeroMortexX",
        "TriuneAutocombat",
        "main"
    },
    {
        "gennro",
        "Gennro Official",
        "github",
        "gennro",
        "TriuneAutocombat",
        "main"
    }
};

constexpr size_t kProfileCount =
    sizeof(kProfiles) /
    sizeof(kProfiles[0]);

std::string g_activeProfile = kDefaultProfileId;
bool g_configurationLoaded = false;
std::string g_configurationPath;
std::string g_configurationError;
std::vector<profilemodel::Profile> g_managedProfiles;
std::string g_profileStorePath;
std::string g_profileStoreError;
bool g_autoCheckOnLoad = false;
bool g_autoUpstreamOnLoad = false;
bool g_autoMonitorOnLoad = false;
int g_autoCheckIntervalMinutes = 0;
int g_networkTimeoutSeconds = 15;
int g_networkRetryCount = 2;
std::chrono::steady_clock::time_point g_nextAutomaticCheck;

fs::path GetProfileTransferPath();
fs::path GetDiagnosticsPath();

const ProfileDefinition* FindProfileDefinition(const std::string& id)
{
    for (const auto& profile : kProfiles)
    {
        if (id == profile.id)
            return &profile;
    }

    return nullptr;
}

const ProfileDefinition& GetActiveProfileDefinition()
{
    const ProfileDefinition* profile =
        FindProfileDefinition(g_activeProfile);

    return profile ? *profile : kProfiles[0];
}

std::string g_phase = "Idle";
int g_progress = 0;
bool g_stageReady = false;
bool g_restartRequired = false;

    std::string g_upstreamDisplayName;
    std::string g_upstreamReference;
    // Lua paths in the compatibility scanner follow the saved Main mapping.
    std::string LuaRemotePrefix(const profilemodel::Profile& profile)
    {
        for (const auto& mapping : profile.mappings)
        {
            if (mapping.enabled &&
                mapping.destinationRoot == profilemodel::DestinationRoot::Lua)
            {
                std::string root =
                    mq2webupdate::planner::NormalizeRepositoryPath(mapping.remotePath);
                if (!root.empty() && root.back() != '/') root += '/';
                return root;
            }
        }
        return {};
    }

    std::string GitHubHttpError(const cpr::Response& response);

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
            g_lastError = GitHubHttpError(response);

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
            GetActiveProfileDefinition().owner + "/" + GetActiveProfileDefinition().repository +
            "/commits/" + GetActiveProfileDefinition().branch;

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
                GetActiveProfileDefinition().owner,
                GetActiveProfileDefinition().repository,
                GetActiveProfileDefinition().branch
            );

            WriteChatf(
                "\at[MQ2WebUpdate]\ax %s",
                g_remoteSha.c_str()
            );
        }

        return true;
    }

    UpstreamWorkerResult RunUpstreamWorker(profilemodel::Profile profile)
    {
        UpstreamWorkerResult result;
        result.status = "Checking";

        try
        {
            const std::string url =
                std::string("https://api.github.com/repos/") +
                profile.owner + "/" +
                profile.repository +
                "/commits/" +
                profile.reference;

            auto response = GitHubGet(url);

            if (response.error)
            {
                result.status = "Error";
                result.lastError =
                    response.error.message;

                return result;
            }

            if (response.status_code != 200)
            {
                result.status = "Error";
                result.lastError = GitHubHttpError(response);

                return result;
            }

            result.remoteSha =
                ExtractJsonString(
                    response.text,
                    "sha"
                );

            if (result.remoteSha.empty())
            {
                result.status = "Error";
                result.lastError =
                    "Could not parse upstream commit SHA.";

                return result;
            }

            result.success = true;
            result.status = "Ready";
        }
        catch (const std::exception& ex)
        {
            result.success = false;
            result.status = "Error";
            result.lastError =
                std::string(
                    "Upstream check exception: "
                ) + ex.what();
        }
        catch (...)
        {
            result.success = false;
            result.status = "Error";
            result.lastError =
                "Unknown upstream check exception.";
        }

        return result;
    }

    void UpstreamWorkerMain(profilemodel::Profile profile)
    {
        UpstreamWorkerResult result =
            RunUpstreamWorker(std::move(profile));

        {
            std::lock_guard<std::mutex> lock(
                g_upstreamMutex
            );

            g_upstreamCompletedResult =
                std::move(result);

            g_upstreamResultReady = true;
        }

        g_upstreamRunning.store(false);
    }

    bool StartAsyncUpstreamCheck(
        bool announce = false)
    {
        const auto selected = std::find_if(g_managedProfiles.begin(),
            g_managedProfiles.end(), [](const profilemodel::Profile& profile)
            {
                return profile.enabled &&
                    profile.role == profilemodel::ProfileRole::MonitorOnly;
            });
        if (selected == g_managedProfiles.end())
        {
            g_upstreamStatus = "Error";
            g_upstreamLastError = "No enabled Monitor Only repository is configured.";
            return false;
        }
        if (g_upstreamRunning.load())
            return false;

        if (g_upstreamThread.joinable())
            g_upstreamThread.join();

        {
            std::lock_guard<std::mutex> lock(
                g_upstreamMutex
            );

            g_upstreamResultReady = false;
            g_upstreamCompletedResult =
                UpstreamWorkerResult{};
        }

        g_upstreamStatus = "Checking";
        g_upstreamLastError.clear();
        g_upstreamAnnounce = announce;
        g_upstreamDisplayName = selected->name;
        g_upstreamReference = selected->reference;

        g_upstreamRunning.store(true);

        try
        {
            g_upstreamThread =
                std::thread(
                    UpstreamWorkerMain, *selected
                );
        }
        catch (const std::exception& ex)
        {
            g_upstreamRunning.store(false);

            g_upstreamStatus = "Error";
            g_upstreamLastError =
                std::string(
                    "Could not start upstream worker: "
                ) + ex.what();

            return false;
        }
        catch (...)
        {
            g_upstreamRunning.store(false);

            g_upstreamStatus = "Error";
            g_upstreamLastError =
                "Could not start upstream worker.";

            return false;
        }

        return true;
    }

    void PublishAsyncUpstreamResult()
    {
        UpstreamWorkerResult result;

        {
            std::lock_guard<std::mutex> lock(
                g_upstreamMutex
            );

            if (!g_upstreamResultReady)
                return;

            result =
                std::move(
                    g_upstreamCompletedResult
                );

            g_upstreamCompletedResult =
                UpstreamWorkerResult{};

            g_upstreamResultReady = false;
        }

        if (g_upstreamThread.joinable())
            g_upstreamThread.join();

        g_upstreamSha =
            std::move(result.remoteSha);

        g_upstreamLastError =
            std::move(result.lastError);

        g_upstreamStatus =
            result.status.empty()
                ? "Error"
                : std::move(result.status);

        if (g_upstreamAnnounce)
        {
            if (result.success)
            {
                WriteChatf(
                    "\ag[MQ2WebUpdate]\ax %s monitor %s SHA:",
                    g_upstreamDisplayName.c_str(), g_upstreamReference.c_str()
                );

                WriteChatf(
                    "\at[MQ2WebUpdate]\ax %s",
                    g_upstreamSha.c_str()
                );
            }
            else
            {
                WriteChatf(
                    "\ar[MQ2WebUpdate]\ax Upstream check failed: %s",
                    g_upstreamLastError.c_str()
                );
            }
        }

        g_upstreamAnnounce = false;
    }
    bool ScanRemoteLuaFiles(bool announceFiles = true)
    {
        g_status = "Scanning";
        g_lastError.clear();
        g_remoteFiles.clear();
        std::string luaPrefix;
        for (const auto& profile : g_managedProfiles)
            if (profile.enabled &&
                profile.role == profilemodel::ProfileRole::MainDownload)
                luaPrefix = LuaRemotePrefix(profile);

        if (!CheckRemoteSha(false))
            return false;

        const std::string url =
            std::string("https://api.github.com/repos/") +
            GetActiveProfileDefinition().owner + "/" + GetActiveProfileDefinition().repository +
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

            if (!luaPrefix.empty() && path.rfind(luaPrefix, 0) == 0)
            {
                std::string relative =
                    path.substr(
                        luaPrefix.size()
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

    fs::path GetConfigurationPath()
    {
        const fs::path luaDirectory =
            GetRuntimeLuaDirectory();

        if (luaDirectory.empty())
            return {};

        return luaDirectory.parent_path() /
            "config" /
            "MQ2WebUpdate.ini";
    }

    bool PersistActiveProfile()
    {
        const fs::path path = GetConfigurationPath();

        if (path.empty())
            return false;

        std::error_code ec;
        fs::create_directories(path.parent_path(), ec);

        if (ec)
            return false;

        const fs::path temp = path.wstring() + L".tmp";

        {
            std::ofstream output(
                temp,
                std::ios::binary | std::ios::trunc);

            if (!output)
                return false;

            output
                << "; Created by: NeroMorte - MQ2WebUpdate user settings\n"
                << "; Written atomically by MQ2WebUpdate.\n"
                << "[Source]\n"
                << "ActiveProfile=" << g_activeProfile << "\n"
                << "\n[Automation]\n"
                << "CheckOnLoad=" << (g_autoCheckOnLoad ? 1 : 0) << "\n"
                << "UpstreamOnLoad=" << (g_autoUpstreamOnLoad ? 1 : 0) << "\n"
                << "MonitorOnLoad=" << (g_autoMonitorOnLoad ? 1 : 0) << "\n"
                << "CheckIntervalMinutes=" << g_autoCheckIntervalMinutes << "\n"
                << "\n[Network]\n"
                << "TimeoutSeconds=" << g_networkTimeoutSeconds << "\n"
                << "RetryCount=" << g_networkRetryCount << "\n";

            if (!output.good())
                return false;
        }

        if (!MoveFileExW(
                temp.c_str(),
                path.c_str(),
                MOVEFILE_REPLACE_EXISTING |
                MOVEFILE_WRITE_THROUGH))
        {
            fs::remove(temp, ec);
            return false;
        }

        g_configurationPath = path.string();
        g_configurationLoaded = true;
        g_configurationError.clear();
        return true;
    }

    void LoadConfiguration()
    {
        g_activeProfile = kDefaultProfileId;
        g_autoCheckOnLoad = false;
        g_autoUpstreamOnLoad = false;
        g_autoMonitorOnLoad = false;
        g_autoCheckIntervalMinutes = 0;
        g_networkTimeoutSeconds = 15;
        g_networkRetryCount = 2;
        g_configurationLoaded = false;
        g_configurationError.clear();

        const fs::path path = GetConfigurationPath();
        g_configurationPath = path.string();

        if (path.empty())
            return;

        std::ifstream input(path, std::ios::binary);

        if (!input)
        {
            // First run is not an error. Publish the safe default atomically.
            PersistActiveProfile();
            return;
        }

        std::string line;

        while (std::getline(input, line))
        {
            if (!line.empty() && line.back() == '\r')
                line.pop_back();

            const auto equals = line.find('=');

            if (equals == std::string::npos)
                continue;

            const std::string key = line.substr(0, equals);
            const std::string value = line.substr(equals + 1);

            if (key == "ActiveProfile")
            {
                if (FindProfileDefinition(value))
                    g_activeProfile = value;
                else
                    g_configurationError = "Invalid ActiveProfile; using morte.";
            }
            else if (key == "CheckOnLoad")
            {
                g_autoCheckOnLoad = value == "1";
            }
            else if (key == "UpstreamOnLoad")
            {
                g_autoUpstreamOnLoad = value == "1";
            }
            else if (key == "MonitorOnLoad")
            {
                g_autoMonitorOnLoad = value == "1";
            }
            else if (key == "CheckIntervalMinutes")
            {
                try
                {
                    const int parsed = std::stoi(value);

                    if (parsed == 0 ||
                        (parsed >= 15 && parsed <= 1440))
                    {
                        g_autoCheckIntervalMinutes = parsed;
                    }
                    else
                    {
                        g_configurationError =
                            "Invalid automatic interval; disabled.";
                    }
                }
                catch (...)
                {
                    g_configurationError =
                        "Invalid automatic interval; disabled.";
                }
            }
            else if (key == "TimeoutSeconds")
            {
                try
                {
                    const int parsed = std::stoi(value);
                    if (parsed >= 5 && parsed <= 120)
                        g_networkTimeoutSeconds = parsed;
                    else
                        g_configurationError = "Invalid network timeout; using 15 seconds.";
                }
                catch (...)
                {
                    g_configurationError = "Invalid network timeout; using 15 seconds.";
                }
            }
            else if (key == "RetryCount")
            {
                try
                {
                    const int parsed = std::stoi(value);
                    if (parsed >= 0 && parsed <= 5)
                        g_networkRetryCount = parsed;
                    else
                        g_configurationError = "Invalid network retry count; using 2.";
                }
                catch (...)
                {
                    g_configurationError = "Invalid network retry count; using 2.";
                }
            }
        }

        g_configurationLoaded = true;
        g_nextAutomaticCheck =
            std::chrono::steady_clock::now() +
            std::chrono::minutes(
                std::max(g_autoCheckIntervalMinutes, 1));
    }

    bool ParseEnabledValue(
        const std::string& value,
        bool& enabled)
    {
        if (value == "on" || value == "true" || value == "1")
        {
            enabled = true;
            return true;
        }

        if (value == "off" || value == "false" || value == "0")
        {
            enabled = false;
            return true;
        }

        return false;
    }

    bool SaveAutomationSetting(
        const std::string& key,
        const std::string& value)
    {
        const bool oldCheckOnLoad = g_autoCheckOnLoad;
        const bool oldUpstreamOnLoad = g_autoUpstreamOnLoad;
        const bool oldMonitorOnLoad = g_autoMonitorOnLoad;
        const int oldInterval = g_autoCheckIntervalMinutes;
        const int oldTimeout = g_networkTimeoutSeconds;
        const int oldRetries = g_networkRetryCount;
        bool valid = true;

        if (key == "checkonload")
        {
            valid = ParseEnabledValue(value, g_autoCheckOnLoad);
        }
        else if (key == "upstreamonload")
        {
            valid = ParseEnabledValue(value, g_autoUpstreamOnLoad);
        }
        else if (key == "monitoronload")
        {
            valid = ParseEnabledValue(value, g_autoMonitorOnLoad);
        }
        else if (key == "interval")
        {
            try
            {
                const int parsed = std::stoi(value);
                valid = parsed == 0 || (parsed >= 15 && parsed <= 1440);

                if (valid)
                    g_autoCheckIntervalMinutes = parsed;
            }
            catch (...)
            {
                valid = false;
            }
        }
        else if (key == "timeout")
        {
            try
            {
                const int parsed = std::stoi(value);
                valid = parsed >= 5 && parsed <= 120;
                if (valid) g_networkTimeoutSeconds = parsed;
            }
            catch (...) { valid = false; }
        }
        else if (key == "retries")
        {
            try
            {
                const int parsed = std::stoi(value);
                valid = parsed >= 0 && parsed <= 5;
                if (valid) g_networkRetryCount = parsed;
            }
            catch (...) { valid = false; }
        }
        else
        {
            valid = false;
        }

        if (!valid || !PersistActiveProfile())
        {
            g_autoCheckOnLoad = oldCheckOnLoad;
            g_autoUpstreamOnLoad = oldUpstreamOnLoad;
            g_autoMonitorOnLoad = oldMonitorOnLoad;
            g_autoCheckIntervalMinutes = oldInterval;
            g_networkTimeoutSeconds = oldTimeout;
            g_networkRetryCount = oldRetries;
            g_lastError = valid
                ? "Could not atomically save MQ2WebUpdate settings."
                : "Invalid setting name or value.";
            return false;
        }

        g_nextAutomaticCheck =
            std::chrono::steady_clock::now() +
            std::chrono::minutes(
                std::max(g_autoCheckIntervalMinutes, 1));
        g_lastError.clear();
        return true;
    }

    bool HasActiveTransactionRecord();

    bool ResetConfiguration()
    {
        const std::string oldProfile = g_activeProfile;
        const bool oldCheckOnLoad = g_autoCheckOnLoad;
        const bool oldUpstreamOnLoad = g_autoUpstreamOnLoad;
        const bool oldMonitorOnLoad = g_autoMonitorOnLoad;
        const int oldInterval = g_autoCheckIntervalMinutes;
        const int oldTimeout = g_networkTimeoutSeconds;
        const int oldRetries = g_networkRetryCount;

        if (g_compareRunning.load() || g_upstreamRunning.load() ||
            g_monitorRunning.load() ||
            g_stageReady || HasActiveTransactionRecord())
        {
            g_lastError =
                "Configuration reset is locked while work, staged data, "
                "or an active transaction exists.";
            return false;
        }

        g_activeProfile = kDefaultProfileId;
        g_autoCheckOnLoad = false;
        g_autoUpstreamOnLoad = false;
        g_autoMonitorOnLoad = false;
        g_autoCheckIntervalMinutes = 0;
        g_networkTimeoutSeconds = 15;
        g_networkRetryCount = 2;

        if (!PersistActiveProfile())
        {
            g_activeProfile = oldProfile;
            g_autoCheckOnLoad = oldCheckOnLoad;
            g_autoUpstreamOnLoad = oldUpstreamOnLoad;
            g_autoMonitorOnLoad = oldMonitorOnLoad;
            g_autoCheckIntervalMinutes = oldInterval;
            g_networkTimeoutSeconds = oldTimeout;
            g_networkRetryCount = oldRetries;
            g_lastError = "Could not atomically reset MQ2WebUpdate settings.";
            return false;
        }

        g_nextAutomaticCheck =
            std::chrono::steady_clock::now() + std::chrono::minutes(1);
        g_lastError.clear();
        return true;
    }

    bool HasActiveTransactionRecord()
    {
        const fs::path luaDirectory = GetRuntimeLuaDirectory();

        if (luaDirectory.empty())
            return true;

        std::error_code ec;
        const fs::path activeRecord =
            luaDirectory.parent_path() /
            "webupdate_recovery" /
            "active_transaction.ini";

        const bool exists = fs::exists(activeRecord, ec);
        return ec || exists;
    }

    std::vector<profilemodel::Profile> BuildDefaultManagedProfiles()
    {
        auto MakeTriuneProfile = [](
            const std::string& id,
            const std::string& name,
            const std::string& owner)
        {
            profilemodel::Profile profile;
            profile.id = id;
            profile.name = name;
            profile.owner = owner;
            profile.repository = "TriuneAutocombat";
            profile.reference = "main";
            profile.channel = "stable";

            profilemodel::Mapping mapping;
            mapping.id = "triune-lua";
            mapping.name = "Triune Lua files";
            mapping.remotePath = "TAC/lua";
            mapping.destinationRoot =
                profilemodel::DestinationRoot::Lua;
            mapping.destinationPath.clear();
            mapping.recursive = true;
            mapping.required = true;
            mapping.restartRequired = false;
            mapping.includePatterns = { "**" };
            mapping.maximumFileBytes = 64ull * 1024ull * 1024ull;
            profile.mappings.push_back(std::move(mapping));
            return profile;
        };

        auto morte =
            MakeTriuneProfile("morte", "NeroMorte", "XxNeroMortexX");
        auto gennro =
            MakeTriuneProfile("gennro", "Gennro Official", "gennro");
        morte.role = profilemodel::ProfileRole::MainDownload;
        gennro.role = profilemodel::ProfileRole::MonitorOnly;
        gennro.monitorOnStartup = true;
        gennro.monitorIntervalMinutes = 60;
        gennro.notificationsEnabled = true;
        return { std::move(morte), std::move(gennro) };
    }

    bool SnapshotMainDownloadProfile(
        profilemodel::Profile& snapshot,
        std::string& error)
    {
        const auto validation =
            profilemodel::ValidateProfileSet(g_managedProfiles);

        if (!validation.IsValid())
        {
            error = "Repository profiles are invalid: " +
                validation.errors.front().message;
            return false;
        }

        const auto found = std::find_if(
            g_managedProfiles.begin(),
            g_managedProfiles.end(),
            [](const profilemodel::Profile& profile)
            {
                return profile.enabled &&
                    profile.role == profilemodel::ProfileRole::MainDownload;
            });

        if (found == g_managedProfiles.end())
        {
            error = "No enabled Main Download repository exists.";
            return false;
        }

        snapshot = *found;
        return true;
    }

    fs::path GetProfileStorePath()
    {
        const fs::path luaDirectory = GetRuntimeLuaDirectory();

        if (luaDirectory.empty())
            return {};

        return luaDirectory.parent_path() /
            "config" /
            "MQ2WebUpdate.profiles.ini";
    }

    bool WriteProfileStoreAtomic(
        const std::vector<profilemodel::Profile>& profiles)
    {
        const auto setValidation =
            profilemodel::ValidateProfileSet(profiles);

        if (!setValidation.IsValid())
        {
            g_profileStoreError =
                "Refusing to save an invalid update profile set: " +
                setValidation.errors.front().message;
            return false;
        }

        const fs::path path = GetProfileStorePath();

        if (path.empty())
        {
            g_profileStoreError = "Could not resolve the profile-store path.";
            return false;
        }

        std::error_code ec;
        fs::create_directories(path.parent_path(), ec);

        if (ec)
        {
            g_profileStoreError = "Could not create the profile-store directory.";
            return false;
        }

        const std::string data =
            profilemodel::SerializeProfiles(profiles);
        fs::path temp = path;
        temp += ".tmp";

        {
            std::ofstream output(temp, std::ios::binary | std::ios::trunc);

            if (!output)
            {
                g_profileStoreError = "Could not create the temporary profile store.";
                return false;
            }

            output.write(data.data(), static_cast<std::streamsize>(data.size()));

            if (!output.good())
            {
                g_profileStoreError = "Could not write the temporary profile store.";
                return false;
            }
        }

        std::string verify;
        {
            std::ifstream verifyInput(temp, std::ios::binary);
            verify.assign(
                std::istreambuf_iterator<char>(verifyInput),
                std::istreambuf_iterator<char>());
        }

        if (verify != data)
        {
            fs::remove(temp, ec);
            g_profileStoreError = "Temporary profile-store verification failed.";
            return false;
        }

        if (!MoveFileExW(
                temp.wstring().c_str(),
                path.wstring().c_str(),
                MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
        {
            fs::remove(temp, ec);
            g_profileStoreError = "Atomic profile-store publication failed.";
            return false;
        }

        g_profileStorePath = path.string();
        g_profileStoreError.clear();
        return true;
    }

    bool LoadManagedProfiles()
    {
        const fs::path path = GetProfileStorePath();
        g_profileStorePath = path.string();
        g_profileStoreError.clear();

        if (path.empty())
        {
            g_profileStoreError = "Could not resolve the profile-store path.";
            return false;
        }

        std::ifstream input(path, std::ios::binary);

        if (!input)
        {
            const auto defaults = BuildDefaultManagedProfiles();

            if (!WriteProfileStoreAtomic(defaults))
                return false;

            g_managedProfiles = defaults;
            return true;
        }

        const std::string data(
            (std::istreambuf_iterator<char>(input)),
            std::istreambuf_iterator<char>());
        std::vector<profilemodel::Profile> parsed;

        if (!profilemodel::ParseProfileStore(
                data,
                parsed,
                g_profileStoreError))
        {
            return false;
        }

        g_managedProfiles = std::move(parsed);
        return true;
    }

    profilemodel::Profile* FindManagedProfile(const std::string& id)
    {
        const auto found = std::find_if(
            g_managedProfiles.begin(),
            g_managedProfiles.end(),
            [&](const profilemodel::Profile& profile)
            {
                return profile.id == id;
            });

        return found == g_managedProfiles.end() ? nullptr : &*found;
    }

    const profilemodel::Profile* GetManagedMainProfile()
    {
        const auto found = std::find_if(
            g_managedProfiles.begin(), g_managedProfiles.end(),
            [](const profilemodel::Profile& profile)
            {
                return profile.enabled &&
                    profile.role == profilemodel::ProfileRole::MainDownload;
            });
        return found == g_managedProfiles.end() ? nullptr : &*found;
    }

    profilemodel::Mapping* FindManagedMapping(
        profilemodel::Profile& profile,
        const std::string& id)
    {
        const auto found = std::find_if(
            profile.mappings.begin(),
            profile.mappings.end(),
            [&](const profilemodel::Mapping& mapping)
            {
                return mapping.id == id;
            });

        return found == profile.mappings.end() ? nullptr : &*found;
    }

    bool CanEditManagedProfiles(std::string& error)
    {
        if (g_compareRunning.load() || g_upstreamRunning.load() ||
            g_monitorRunning.load() ||
            g_stageReady || HasActiveTransactionRecord())
        {
            error =
                "Profile editing is locked while work, staged data, "
                "or an active transaction exists.";
            return false;
        }

        error.clear();
        return true;
    }

    bool CommitManagedProfiles(
        std::vector<profilemodel::Profile> candidate,
        std::string& error)
    {
        const auto validation =
            profilemodel::ValidateProfileSet(candidate);

        if (!validation.IsValid())
        {
            error = validation.errors.front().field + ": " +
                validation.errors.front().message;
            return false;
        }

        if (!WriteProfileStoreAtomic(candidate))
        {
            error = g_profileStoreError;
            return false;
        }

        g_managedProfiles = std::move(candidate);

        const auto now = std::chrono::steady_clock::now();
        std::map<std::string, std::chrono::steady_clock::time_point> schedule;
        for (const auto& profile : g_managedProfiles)
        {
            if (!profile.enabled ||
                profile.role != profilemodel::ProfileRole::MonitorOnly ||
                profile.monitorIntervalMinutes == 0)
                continue;

            const auto previous = g_monitorNextCheck.find(profile.id);
            schedule[profile.id] = previous != g_monitorNextCheck.end()
                ? previous->second
                : now + std::chrono::minutes(profile.monitorIntervalMinutes);
        }
        g_monitorNextCheck = std::move(schedule);
        g_monitorStates.clear();
        g_repositoryViews.clear();
        error.clear();
        return true;
    }

    bool CreateManagedProfile(
        const std::string& id,
        std::string& error)
    {
        if (!CanEditManagedProfiles(error))
            return false;

        if (!profilemodel::IsAsciiIdentifier(id) || FindManagedProfile(id))
        {
            error = "Profile ID is invalid or already exists.";
            return false;
        }

        auto candidate = g_managedProfiles;
        profilemodel::Profile profile;
        profile.id = id;
        profile.name = id;
        profile.role = profilemodel::ProfileRole::MonitorOnly;
        profile.owner = "owner";
        profile.repository = "repository";
        profile.reference = "main";

        profilemodel::Mapping mapping;
        mapping.id = "files";
        mapping.name = "Files";
        mapping.remotePath = "files";
        mapping.destinationRoot = profilemodel::DestinationRoot::Lua;
        mapping.includePatterns = { "**" };
        profile.mappings.push_back(std::move(mapping));
        candidate.push_back(std::move(profile));
        return CommitManagedProfiles(std::move(candidate), error);
    }

    bool DeleteManagedProfile(
        const std::string& id,
        std::string& error)
    {
        if (!CanEditManagedProfiles(error))
            return false;

        if (id == "morte" || id == "gennro" || id == g_activeProfile)
        {
            error = "Built-in or active profiles cannot be deleted.";
            return false;
        }

        auto candidate = g_managedProfiles;
        const auto found = std::find_if(
            candidate.begin(), candidate.end(),
            [&](const profilemodel::Profile& profile)
            {
                return profile.id == id;
            });

        if (found == candidate.end())
        {
            error = "Profile was not found.";
            return false;
        }

        candidate.erase(found);

        if (!CommitManagedProfiles(std::move(candidate), error))
            return false;

#ifdef _WIN32
        std::string credentialError;
        mq2webupdate::credentials::DeleteGitHubToken(id, credentialError);
#endif
        g_monitorStates.erase(id);
        g_repositoryViews.erase(id);
        return true;
    }

    bool DuplicateManagedProfile(
        const std::string& sourceId,
        const std::string& newId,
        std::string& error)
    {
        if (!CanEditManagedProfiles(error))
            return false;

        if (!profilemodel::IsAsciiIdentifier(newId) ||
            FindManagedProfile(newId))
        {
            error = "The new profile ID is invalid or already exists.";
            return false;
        }

        const profilemodel::Profile* source =
            FindManagedProfile(sourceId);
        if (!source)
        {
            error = "The source profile was not found.";
            return false;
        }

        auto candidate = g_managedProfiles;
        profilemodel::Profile copy = *source;
        copy.id = newId;
        copy.name += " Copy";
        copy.role = profilemodel::ProfileRole::MonitorOnly;
        copy.enabled = true;
        copy.privateRepository = false;
        candidate.push_back(std::move(copy));
        return CommitManagedProfiles(std::move(candidate), error);
    }

    bool SetManagedProfileField(
        const std::string& id,
        const std::string& field,
        const std::string& value,
        std::string& error)
    {
        if (!CanEditManagedProfiles(error))
            return false;

        auto candidate = g_managedProfiles;
        auto found = std::find_if(
            candidate.begin(), candidate.end(),
            [&](const profilemodel::Profile& profile)
            {
                return profile.id == id;
            });

        if (found == candidate.end())
        {
            error = "Profile was not found.";
            return false;
        }

        if (field == "name") found->name = value;
        else if (field == "owner") found->owner = value;
        else if (field == "repository") found->repository = value;
        else if (field == "reference") found->reference = value;
        else if (field == "channel") found->channel = value;
        else if (field == "enabled")
        {
            if (!ParseEnabledValue(value, found->enabled))
            {
                error = "Enabled must be on or off.";
                return false;
            }
        }
        else if (field == "private")
        {
            if (!ParseEnabledValue(value, found->privateRepository))
            {
                error = "Private must be on or off.";
                return false;
            }
        }
        else if (field == "monitorstartup")
        {
            if (!ParseEnabledValue(value, found->monitorOnStartup))
            {
                error = "Monitor startup must be on or off.";
                return false;
            }
        }
        else if (field == "notifications")
        {
            if (!ParseEnabledValue(value, found->notificationsEnabled))
            {
                error = "Notifications must be on or off.";
                return false;
            }
        }
        else if (field == "monitorinterval")
        {
            std::uint64_t parsed = 0;
            if (!profilemodel::ParseUnsigned(value, parsed) || parsed > 10080)
            {
                error = "Monitor interval must be 0-10080 minutes.";
                return false;
            }
            found->monitorIntervalMinutes = static_cast<std::uint32_t>(parsed);
        }
        else if (field == "acknowledgedsha")
        {
            found->acknowledgedSha = value;
        }
        else if (field == "role")
        {
            const auto role = profilemodel::ParseProfileRole(value);

            if (!role)
            {
                error = "Role must be main, monitor, or disabled.";
                return false;
            }

            if (*role == profilemodel::ProfileRole::MainDownload)
            {
                for (auto& profile : candidate)
                {
                    if (profile.role == profilemodel::ProfileRole::MainDownload)
                        profile.role = profilemodel::ProfileRole::MonitorOnly;
                }

                found->enabled = true;
            }

            found->role = *role;
            found->enabled = *role != profilemodel::ProfileRole::Disabled;
        }
        else
        {
            error = "Profile field is not editable.";
            return false;
        }

        return CommitManagedProfiles(std::move(candidate), error);
    }

    bool CreateManagedMapping(
        const std::string& profileId,
        const std::string& mappingId,
        std::string& error)
    {
        if (!CanEditManagedProfiles(error))
            return false;

        if (!profilemodel::IsAsciiIdentifier(mappingId))
        {
            error = "Mapping ID is invalid.";
            return false;
        }

        auto candidate = g_managedProfiles;
        auto profile = std::find_if(
            candidate.begin(), candidate.end(),
            [&](const profilemodel::Profile& entry)
            {
                return entry.id == profileId;
            });

        if (profile == candidate.end())
        {
            error = "Profile was not found.";
            return false;
        }

        if (FindManagedMapping(*profile, mappingId))
        {
            error = "Mapping ID already exists.";
            return false;
        }

        profilemodel::Mapping mapping;
        mapping.id = mappingId;
        mapping.name = mappingId;
        mapping.remotePath = "files";
        mapping.destinationRoot = profilemodel::DestinationRoot::Lua;
        mapping.includePatterns = { "**" };
        profile->mappings.push_back(std::move(mapping));
        return CommitManagedProfiles(std::move(candidate), error);
    }

    bool DeleteManagedMapping(
        const std::string& profileId,
        const std::string& mappingId,
        std::string& error)
    {
        if (!CanEditManagedProfiles(error))
            return false;

        auto candidate = g_managedProfiles;
        auto profile = std::find_if(
            candidate.begin(), candidate.end(),
            [&](const profilemodel::Profile& entry)
            {
                return entry.id == profileId;
            });

        if (profile == candidate.end())
        {
            error = "Profile was not found.";
            return false;
        }

        if (profile->mappings.size() <= 1)
        {
            error = "A profile must retain at least one mapping.";
            return false;
        }

        const auto mapping = std::find_if(
            profile->mappings.begin(), profile->mappings.end(),
            [&](const profilemodel::Mapping& entry)
            {
                return entry.id == mappingId;
            });

        if (mapping == profile->mappings.end())
        {
            error = "Mapping was not found.";
            return false;
        }

        profile->mappings.erase(mapping);
        return CommitManagedProfiles(std::move(candidate), error);
    }

    bool SetManagedMappingField(
        const std::string& profileId,
        const std::string& mappingId,
        const std::string& field,
        const std::string& value,
        std::string& error)
    {
        if (!CanEditManagedProfiles(error))
            return false;

        auto candidate = g_managedProfiles;
        auto profile = std::find_if(
            candidate.begin(), candidate.end(),
            [&](const profilemodel::Profile& entry)
            {
                return entry.id == profileId;
            });

        if (profile == candidate.end())
        {
            error = "Profile was not found.";
            return false;
        }

        profilemodel::Mapping* mapping =
            FindManagedMapping(*profile, mappingId);

        if (!mapping)
        {
            error = "Mapping was not found.";
            return false;
        }

        if (field == "name") mapping->name = value;
        else if (field == "remote") mapping->remotePath = value;
        else if (field == "destination") mapping->destinationPath = value;
        else if (field == "root")
        {
            const auto root = profilemodel::ParseDestinationRoot(value);

            if (!root)
            {
                error = "Destination root is invalid.";
                return false;
            }

            mapping->destinationRoot = *root;
        }
        else if (field == "enabled")
        {
            if (!ParseEnabledValue(value, mapping->enabled))
            {
                error = "Enabled must be on or off.";
                return false;
            }
        }
        else if (field == "recursive")
        {
            if (!ParseEnabledValue(value, mapping->recursive))
            {
                error = "Recursive must be on or off.";
                return false;
            }
        }
        else if (field == "required")
        {
            if (!ParseEnabledValue(value, mapping->required))
            {
                error = "Required must be on or off.";
                return false;
            }
        }
        else if (field == "restart")
        {
            if (!ParseEnabledValue(value, mapping->restartRequired))
            {
                error = "Restart must be on or off.";
                return false;
            }
        }
        else if (field == "include" || field == "exclude")
        {
            std::vector<std::string> patterns;

            if (!profilemodel::SplitList(value, patterns))
            {
                error = "Pattern list encoding is invalid.";
                return false;
            }

            if (field == "include") mapping->includePatterns = std::move(patterns);
            else mapping->excludePatterns = std::move(patterns);
        }
        else if (field == "maxbytes")
        {
            std::uint64_t parsed = 0;

            if (!profilemodel::ParseUnsigned(value, parsed))
            {
                error = "Maximum file size is invalid.";
                return false;
            }

            mapping->maximumFileBytes = parsed;
        }
        else
        {
            error = "Mapping field is not editable.";
            return false;
        }

        return CommitManagedProfiles(std::move(candidate), error);
    }

    bool AddManagedMappingExclusion(
        const std::string& profileId,
        const std::string& mappingId,
        const std::string& relativePath,
        std::string& error)
    {
        if (!CanEditManagedProfiles(error)) return false;
        if (relativePath.empty() ||
            !profilemodel::IsSafeRelativePath(relativePath))
        {
            error = "The excluded repository-relative path is unsafe.";
            return false;
        }

        auto candidate = g_managedProfiles;
        auto profile = std::find_if(candidate.begin(), candidate.end(),
            [&](const profilemodel::Profile& entry)
            {
                return entry.id == profileId;
            });
        if (profile == candidate.end())
        {
            error = "Profile was not found.";
            return false;
        }

        auto* mapping = FindManagedMapping(*profile, mappingId);
        if (!mapping)
        {
            error = "Mapping was not found.";
            return false;
        }

        if (std::find(mapping->excludePatterns.begin(),
                mapping->excludePatterns.end(), relativePath) ==
            mapping->excludePatterns.end())
        {
            mapping->excludePatterns.push_back(relativePath);
        }

        return CommitManagedProfiles(std::move(candidate), error);
    }

    bool SetManagedMappingSelection(
        const std::string& profileId,
        const std::string& mappingId,
        const std::string& pattern,
        bool selected,
        std::string& error)
    {
        if (!CanEditManagedProfiles(error)) return false;
        if (pattern.empty() || !profilemodel::IsSafeRelativePath(pattern))
        {
            error = "The repository selection path is unsafe.";
            return false;
        }

        auto candidate = g_managedProfiles;
        auto profile = std::find_if(candidate.begin(), candidate.end(),
            [&](const profilemodel::Profile& entry) { return entry.id == profileId; });
        if (profile == candidate.end())
        {
            error = "Profile was not found.";
            return false;
        }
        auto* mapping = FindManagedMapping(*profile, mappingId);
        if (!mapping)
        {
            error = "Mapping was not found.";
            return false;
        }

        auto& exclusions = mapping->excludePatterns;
        const auto existing = std::find(exclusions.begin(), exclusions.end(), pattern);
        if (selected)
        {
            if (existing != exclusions.end()) exclusions.erase(existing);
        }
        else if (existing == exclusions.end())
        {
            exclusions.push_back(pattern);
        }
        return CommitManagedProfiles(std::move(candidate), error);
    }

    bool SetManagedMappingFolderSelection(
        const std::string& profileId,
        const std::string& mappingId,
        const std::string& folder,
        bool selected,
        std::string& error)
    {
        if (!CanEditManagedProfiles(error)) return false;
        if (folder.empty() || !profilemodel::IsSafeRelativePath(folder))
        {
            error = "The repository folder is unsafe.";
            return false;
        }
        auto candidate = g_managedProfiles;
        auto profile = std::find_if(candidate.begin(), candidate.end(),
            [&](const profilemodel::Profile& entry) { return entry.id == profileId; });
        if (profile == candidate.end())
        {
            error = "Profile was not found.";
            return false;
        }
        auto* mapping = FindManagedMapping(*profile, mappingId);
        if (!mapping)
        {
            error = "Mapping was not found.";
            return false;
        }

        const std::string prefix =
            mq2webupdate::planner::NormalizeRepositoryPath(folder) + "/";
        const std::string folderPattern = prefix + "**";
        auto& exclusions = mapping->excludePatterns;
        if (selected)
        {
            exclusions.erase(std::remove_if(exclusions.begin(), exclusions.end(),
                [&](const std::string& value)
                {
                    return value == folderPattern || value.rfind(prefix, 0) == 0;
                }), exclusions.end());
        }
        else if (std::find(exclusions.begin(), exclusions.end(), folderPattern) == exclusions.end())
        {
            exclusions.push_back(folderPattern);
        }
        return CommitManagedProfiles(std::move(candidate), error);
    }

    bool SelectActiveProfile(const std::string& requested)
    {
        const ProfileDefinition* profile =
            FindProfileDefinition(requested);

        if (!profile)
        {
            g_lastError = "Unknown trusted update profile: " + requested;
            return false;
        }

        if (g_compareRunning.load() ||
            g_upstreamRunning.load() ||
            g_compareThread.joinable() ||
            g_upstreamThread.joinable() ||
            g_stageReady ||
            HasActiveTransactionRecord())
        {
            g_lastError =
                "Profile switching is locked while work, staged data, "
                "or an active transaction exists.";
            return false;
        }

        const std::string previous = g_activeProfile;
        g_activeProfile = profile->id;

        if (!PersistActiveProfile())
        {
            g_activeProfile = previous;
            g_lastError = "Could not atomically save MQ2WebUpdate settings.";
            return false;
        }

        g_remoteSha.clear();
        g_remoteFiles.clear();
        g_fileResults.clear();
        g_sameCount = 0;
        g_updateCount = 0;
        g_missingCount = 0;
        g_protectedCount = 0;
        g_errorCount = 0;
        g_status = "Ready";
        g_phase = "Idle";
        g_progress = 0;
        g_lastError.clear();
        return true;
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

    // Created by: NeroMorte - Reject a destination when its trusted
    // root or any existing parent component is a reparse point.
    // Lexical comparison is intentional so validation never follows a link.
    bool HasReparsePointInPath(
        const fs::path& trustedRoot,
        const fs::path& destination)
    {
        if (trustedRoot.empty() || destination.empty())
            return true;

        const fs::path root =
            trustedRoot.lexically_normal();

        const fs::path target =
            destination.lexically_normal();

        if (!root.is_absolute() ||
            !target.is_absolute())
        {
            return true;
        }

        auto rootPart = root.begin();
        auto targetPart = target.begin();

        for (;
             rootPart != root.end();
             ++rootPart, ++targetPart)
        {
            if (targetPart == target.end() ||
                *rootPart != *targetPart)
            {
                return true;
            }
        }

        if (targetPart == target.end())
            return true;

        if (IsReparsePoint(root))
            return true;

        fs::path current = root;

        for (; targetPart != target.end(); ++targetPart)
        {
            auto nextPart = targetPart;
            ++nextPart;

            if (nextPart == target.end())
                break;

            current /= *targetPart;

            std::error_code ec;
            const fs::file_status status =
                fs::symlink_status(current, ec);

            if (ec)
                return true;

            if (status.type() == fs::file_type::not_found)
                break;

            if (IsReparsePoint(current))
                return true;

            if (!fs::is_directory(status))
                return true;
        }

        return false;
    }

    // Created by: NeroMorte - Produce a durable SHA-256 identity
    // for staged bytes so recovery can prove updater ownership.
    std::string ComputeSHA256Hex(
        const std::string& data)
    {
        unsigned char digest[SHA256_DIGEST_LENGTH] = {};

        if (SHA256(
                reinterpret_cast<const unsigned char*>(
                    data.data()
                ),
                data.size(),
                digest) == nullptr)
        {
            return {};
        }

        static constexpr char kHex[] =
            "0123456789abcdef";

        std::string result;
        result.resize(SHA256_DIGEST_LENGTH * 2);

        for (size_t i = 0;
             i < SHA256_DIGEST_LENGTH;
             ++i)
        {
            result[i * 2] =
                kHex[(digest[i] >> 4) & 0x0F];

            result[i * 2 + 1] =
                kHex[digest[i] & 0x0F];
        }

        return result;
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
            GetActiveProfileDefinition().owner + "/" +
            GetActiveProfileDefinition().repository + "/" +
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

    bool WriteFileBinaryAtomic(
        const fs::path& path,
        const std::string& data)
    {
        fs::path temp = path;
        temp += ".mq2webupdate.tmp";
        std::error_code ec;
        fs::remove(temp, ec);
        if (!WriteFileBinary(temp, data)) return false;

        std::string verify;
        if (!ReadFileBinary(temp, verify) || verify != data)
        {
            fs::remove(temp, ec);
            return false;
        }

        if (!MoveFileExW(
                temp.wstring().c_str(), path.wstring().c_str(),
                MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
        {
            fs::remove(temp, ec);
            return false;
        }

        return ReadFileBinary(path, verify) && verify == data;
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
        const profilemodel::Profile& profile,
        const std::string& sha)
    {
        std::ostringstream data;

        data
            << "Repository="
            << profile.owner << "/" << profile.repository << "\n"
            << "Branch="
            << profile.reference << "\n"
            << "SHA="
            << sha << "\n";

        return WriteFileBinary(
            metadataPath,
            data.str()
        );
    }

    std::string ResponseHeaderValue(
        const cpr::Response& response,
        const std::string& wanted);

    cpr::Response GitHubProviderGet(
        const std::string& url,
        const std::string& token,
        bool rawContent)
    {
        cpr::Header headers{
            { "User-Agent", "MQ2WebUpdate" },
            { "Accept", rawContent
                ? "application/vnd.github.raw+json"
                : "application/vnd.github+json" },
            { "X-GitHub-Api-Version", "2022-11-28" }
        };

        if (!token.empty())
            headers["Authorization"] = "Bearer " + token;

        cpr::Response response;
        for (int attempt = 0; attempt <= g_networkRetryCount; ++attempt)
        {
            {
                std::lock_guard<std::mutex> requestLock(g_githubRequestMutex);
                const auto now = std::chrono::steady_clock::now();
                const auto earliest = g_lastGitHubRequest +
                    std::chrono::milliseconds(350);
                if (g_lastGitHubRequest.time_since_epoch().count() != 0 &&
                    now < earliest)
                {
                    std::this_thread::sleep_until(earliest);
                }

                response = cpr::Get(
                    cpr::Url{ url },
                    headers,
                    cpr::Timeout{ g_networkTimeoutSeconds * 1000 }
                );
                g_lastGitHubRequest = std::chrono::steady_clock::now();
            }

            const std::string retryAfter =
                ResponseHeaderValue(response, "retry-after");
            const bool retryable = static_cast<bool>(response.error) ||
                response.status_code == 408 || response.status_code == 429 ||
                (response.status_code == 403 && !retryAfter.empty()) ||
                response.status_code >= 500;
            if (!retryable || attempt == g_networkRetryCount)
                break;

            int waitMilliseconds = 250 * (attempt + 1);
            if (!retryAfter.empty())
            {
                try
                {
                    waitMilliseconds = std::clamp(
                        std::stoi(retryAfter), 1, 60) * 1000;
                }
                catch (...) {}
            }
            std::this_thread::sleep_for(
                std::chrono::milliseconds(waitMilliseconds));
        }
        return response;
    }

    std::string ResponseHeaderValue(
        const cpr::Response& response,
        const std::string& wanted)
    {
        auto lower = [](std::string value)
        {
            std::transform(value.begin(), value.end(), value.begin(),
                [](unsigned char ch)
                {
                    return static_cast<char>(std::tolower(ch));
                });
            return value;
        };

        const std::string wantedLower = lower(wanted);
        for (const auto& header : response.header)
        {
            if (lower(header.first) == wantedLower)
                return header.second;
        }
        return {};
    }

    std::string FormatGitHubResetTime(const std::string& epochText)
    {
        if (epochText.empty()) return {};
        try
        {
            const std::time_t epoch = static_cast<std::time_t>(
                std::stoll(epochText));
            std::tm local = {};
            if (localtime_s(&local, &epoch) != 0) return {};
            std::ostringstream output;
            output << std::put_time(&local, "%Y-%m-%d %H:%M:%S");
            return output.str();
        }
        catch (...) { return {}; }
    }

    std::string GitHubHttpError(const cpr::Response& response)
    {
        std::ostringstream error;
        error << "GitHub returned HTTP " << response.status_code;

        const std::string remaining =
            ResponseHeaderValue(response, "x-ratelimit-remaining");
        const std::string limit =
            ResponseHeaderValue(response, "x-ratelimit-limit");
        const std::string reset = FormatGitHubResetTime(
            ResponseHeaderValue(response, "x-ratelimit-reset"));
        const std::string retryAfter =
            ResponseHeaderValue(response, "retry-after");

        if (!remaining.empty() || !limit.empty())
        {
            error << " (rate limit "
                << (remaining.empty() ? "?" : remaining) << "/"
                << (limit.empty() ? "?" : limit) << " remaining)";
        }
        if (!reset.empty()) error << "; resets " << reset;
        if (!retryAfter.empty()) error << "; retry after " << retryAfter << " seconds";
        return error.str();
    }

    std::string ComputeGitBlobSha(const std::string& bytes)
    {
        std::string header = "blob " + std::to_string(bytes.size());
        header.push_back('\0');

        SHA_CTX context = {};
        unsigned char digest[SHA_DIGEST_LENGTH] = {};
        if (SHA1_Init(&context) != 1 ||
            SHA1_Update(&context, header.data(), header.size()) != 1 ||
            SHA1_Update(&context, bytes.data(), bytes.size()) != 1 ||
            SHA1_Final(digest, &context) != 1)
        {
            return {};
        }

        static constexpr char Hex[] = "0123456789abcdef";
        std::string output;
        output.reserve(SHA_DIGEST_LENGTH * 2);
        for (const unsigned char value : digest)
        {
            output.push_back(Hex[(value >> 4) & 0x0f]);
            output.push_back(Hex[value & 0x0f]);
        }
        return output;
    }

    bool IsTextDeployment(const std::string& relativePath)
    {
        std::string ext = fs::path(relativePath).extension().string();
        std::transform(ext.begin(), ext.end(), ext.begin(),
            [](unsigned char ch) { return static_cast<char>(std::tolower(ch)); });
        return ext == ".lua" || ext == ".mac" || ext == ".ini" ||
            ext == ".cfg" || ext == ".txt" || ext == ".json" ||
            ext == ".yaml" || ext == ".yml" || ext == ".xml" ||
            ext == ".toml" || ext == ".md" || ext == ".ps1";
    }

    std::string RepositoryCacheKey(const profilemodel::Profile& profile)
    {
        return profilemodel::SourceProviderName(profile.provider) +
            std::string("|") + profile.owner + "|" + profile.repository +
            "|" + profile.reference;
    }

    bool ReadOptionalGitHubCredential(
        const profilemodel::Profile& profile,
        mq2webupdate::credentials::ScopedSecret& credential,
        std::string& error)
    {
#ifdef _WIN32
        if (mq2webupdate::credentials::HasGitHubToken(profile.id))
        {
            return mq2webupdate::credentials::ReadGitHubToken(
                profile.id, credential.value, error);
        }
        if (mq2webupdate::credentials::HasGitHubToken(
                kGlobalGitHubCredentialId))
        {
            return mq2webupdate::credentials::ReadGitHubToken(
                kGlobalGitHubCredentialId, credential.value, error);
        }
        if (profile.privateRepository)
        {
            error = "Private GitHub repository requires a stored credential.";
            return false;
        }
        error.clear();
        return true;
#else
        if (profile.privateRepository)
        {
            error = "Private GitHub repositories require Windows Credential Manager.";
            return false;
        }
        error.clear();
        return true;
#endif
    }

    bool WriteStageMetadata(
        const fs::path& metadataPath,
        const std::string& sha)
    {
        profilemodel::Profile legacy;
        legacy.owner = GetActiveProfileDefinition().owner;
        legacy.repository = GetActiveProfileDefinition().repository;
        legacy.reference = GetActiveProfileDefinition().branch;
        return WriteStageMetadata(metadataPath, legacy, sha);
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
                std::string(GetActiveProfileDefinition().owner) + "/" + GetActiveProfileDefinition().repository)
        {
            return false;
        }

        if (metadata.branch != GetActiveProfileDefinition().branch)
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

        std::string mainProfileId;
        for (const auto& profile : g_managedProfiles)
            if (profile.enabled &&
                profile.role == profilemodel::ProfileRole::MainDownload)
                mainProfileId = profile.id;
        if (mainProfileId.empty())
        {
            g_lastError = "No Main Download profile is configured.";
            return false;
        }
        fs::path stageRoot = runtimeRoot / "webupdate_stage" / mainProfileId;

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

    // Created by: NeroMorte - Immutable identity snapshot produced
    // by whole-transaction preflight and consumed by Apply.
    struct ApplyPlanEntry
    {
        fs::path stagePath;
        fs::path relativePath;
        fs::path trustedDestinationRoot;
        fs::path livePath;
        bool existedBefore = false;
        std::string stagedSHA256;
        std::string originalSHA256;
    };

    struct AppliedFileChange
    {
        fs::path livePath;
        fs::path backupPath;
        bool existedBefore = false;

        // Created by: NeroMorte - PENDING means the live mutation
        // may or may not have completed if the process stopped.
        std::string transactionState = "PENDING";

        // Created by: NeroMorte - Recovery progress is persisted separately
        // from Apply progress so interrupted recovery can resume safely.
        std::string recoveryState = "NOT_STARTED";

        std::string backupSHA256;
        std::string expectedSHA256;
    };
    // Created by: NeroMorte - Durable Apply transaction state used for
    // recovery if the process stops after live-file replacement begins.
    struct ApplyTransactionManifest
    {
        std::string version = "2";
        std::string state = "PREPARED";
        std::string profileId;
        std::string provider;
        std::string repository;
        std::string branch;
        std::string remoteSha;

        fs::path stageDirectory;
        fs::path backupDirectory;

        std::vector<AppliedFileChange> changes;
    };

    // Created by: NeroMorte - Encode transaction fields so one value
    // cannot inject another line or key into the manifest.
    std::string EscapeApplyManifestValue(
        const std::string& value)
    {
        static const char hex[] =
            "0123456789ABCDEF";

        std::string output;
        output.reserve(value.size());

        for (unsigned char ch : value)
        {
            if (ch == '%' ||
                ch == '\r' ||
                ch == '\n' ||
                ch == '=')
            {
                output.push_back('%');
                output.push_back(
                    hex[(ch >> 4) & 0x0F]
                );
                output.push_back(
                    hex[ch & 0x0F]
                );
            }
            else
            {
                output.push_back(
                    static_cast<char>(ch)
                );
            }
        }

        return output;
    }

    // Created by: NeroMorte - Decode a transaction field while failing
    // closed on malformed percent escapes.
    bool UnescapeApplyManifestValue(
        const std::string& value,
        std::string& output)
    {
        auto HexValue =
            [](char ch) -> int
        {
            if (ch >= '0' && ch <= '9')
                return ch - '0';

            if (ch >= 'A' && ch <= 'F')
                return 10 + (ch - 'A');

            if (ch >= 'a' && ch <= 'f')
                return 10 + (ch - 'a');

            return -1;
        };

        output.clear();
        output.reserve(value.size());

        for (size_t i = 0;
             i < value.size();
             ++i)
        {
            if (value[i] != '%')
            {
                output.push_back(value[i]);
                continue;
            }

            if (i + 2 >= value.size())
                return false;

            const int high =
                HexValue(value[i + 1]);

            const int low =
                HexValue(value[i + 2]);

            if (high < 0 || low < 0)
                return false;

            output.push_back(
                static_cast<char>(
                    (high << 4) | low
                )
            );

            i += 2;
        }

        return true;
    }

    // Created by: NeroMorte - Write durable Apply state using a verified
    // temporary file followed by a write-through atomic replacement.
    bool WriteApplyTransactionManifest(
        const fs::path& manifestPath,
        const ApplyTransactionManifest& manifest)
    {
        std::ostringstream stream;

        stream
            << "Version="
            << EscapeApplyManifestValue(
                manifest.version
            )
            << "\n";

        stream
            << "State="
            << EscapeApplyManifestValue(
                manifest.state
            )
            << "\n";

        stream
            << "Profile="
            << EscapeApplyManifestValue(
                manifest.profileId
            )
            << "\n";

        stream
            << "Provider="
            << EscapeApplyManifestValue(
                manifest.provider
            )
            << "\n";

        stream
            << "Repository="
            << EscapeApplyManifestValue(
                manifest.repository
            )
            << "\n";

        stream
            << "Branch="
            << EscapeApplyManifestValue(
                manifest.branch
            )
            << "\n";

        stream
            << "SHA="
            << EscapeApplyManifestValue(
                manifest.remoteSha
            )
            << "\n";

        stream
            << "StageDirectory="
            << EscapeApplyManifestValue(
                manifest.stageDirectory.string()
            )
            << "\n";

        stream
            << "BackupDirectory="
            << EscapeApplyManifestValue(
                manifest.backupDirectory.string()
            )
            << "\n";

        stream
            << "ChangeCount="
            << manifest.changes.size()
            << "\n";

        for (size_t i = 0;
             i < manifest.changes.size();
             ++i)
        {
            const AppliedFileChange& change =
                manifest.changes[i];

            const std::string prefix =
                "Change." +
                std::to_string(i) +
                ".";

            stream
                << prefix
                << "LivePath="
                << EscapeApplyManifestValue(
                    change.livePath.string()
                )
                << "\n";

            stream
                << prefix
                << "BackupPath="
                << EscapeApplyManifestValue(
                    change.backupPath.string()
                )
                << "\n";

            stream
                << prefix
                << "ExistedBefore="
                << (change.existedBefore ? "1" : "0")
                << "\n";

            stream
                << prefix
                << "TransactionState="
                << EscapeApplyManifestValue(
                    change.transactionState
                )
                << "\n";

            stream
                << prefix
                << "RecoveryState="
                << EscapeApplyManifestValue(
                    change.recoveryState
                )
                << "\n";


            stream
                << prefix
                << "BackupSHA256="
                << EscapeApplyManifestValue(
                    change.backupSHA256
                )
                << "\n";

            stream
                << prefix
                << "ExpectedSHA256="
                << EscapeApplyManifestValue(
                    change.expectedSHA256
                )
                << "\n";
        }

        const std::string data =
            stream.str();

        fs::path tempPath =
            manifestPath;

        tempPath += ".tmp";

        std::error_code ec;

        fs::create_directories(
            manifestPath.parent_path(),
            ec
        );

        if (ec)
            return false;

        ec.clear();

        fs::remove(
            tempPath,
            ec
        );

        if (!WriteFileBinary(
                tempPath,
                data))
        {
            return false;
        }

        std::string verifyTemp;

        if (!ReadFileBinary(
                tempPath,
                verifyTemp) ||
            verifyTemp != data)
        {
            ec.clear();

            fs::remove(
                tempPath,
                ec
            );

            return false;
        }

        if (!MoveFileExW(
                tempPath.wstring().c_str(),
                manifestPath.wstring().c_str(),
                MOVEFILE_REPLACE_EXISTING |
                MOVEFILE_WRITE_THROUGH))
        {
            ec.clear();

            fs::remove(
                tempPath,
                ec
            );

            return false;
        }

        std::string verifyLive;

        if (!ReadFileBinary(
                manifestPath,
                verifyLive) ||
            verifyLive != data)
        {
            return false;
        }

        return true;
    }

    // Created by: NeroMorte - Read and validate durable Apply state.
    // Unknown fields remain forward-compatible, while every required
    // field for the current format must be present exactly once.
    bool ReadApplyTransactionManifest(
        const fs::path& manifestPath,
        ApplyTransactionManifest& manifest)
    {
        std::string data;

        if (!ReadFileBinary(
                manifestPath,
                data))
        {
            return false;
        }

        std::vector<
            std::pair<std::string, std::string>
        > fields;

        std::istringstream stream(data);
        std::string line;

        while (std::getline(
            stream,
            line))
        {
            if (!line.empty() &&
                line.back() == '\r')
            {
                line.pop_back();
            }

            if (line.empty())
                continue;

            const size_t separator =
                line.find('=');

            if (separator ==
                std::string::npos)
            {
                return false;
            }

            const std::string key =
                line.substr(
                    0,
                    separator
                );

            if (key.empty())
                return false;

            std::string decoded;

            if (!UnescapeApplyManifestValue(
                    line.substr(separator + 1),
                    decoded))
            {
                return false;
            }

            for (const auto& existing : fields)
            {
                if (existing.first == key)
                    return false;
            }

            fields.emplace_back(
                key,
                std::move(decoded)
            );
        }

        auto RequireField =
            [&](const std::string& key,
                std::string& output) -> bool
        {
            for (const auto& field : fields)
            {
                if (field.first == key)
                {
                    output =
                        field.second;

                    return true;
                }
            }

            return false;
        };

        ApplyTransactionManifest parsed;

        if (!RequireField(
                "Version",
                parsed.version) ||
            !RequireField(
                "State",
                parsed.state) ||
            !RequireField(
                "Profile",
                parsed.profileId) ||
            !RequireField(
                "Repository",
                parsed.repository) ||
            !RequireField(
                "Branch",
                parsed.branch) ||
            !RequireField(
                "SHA",
                parsed.remoteSha))
        {
            return false;
        }

        if (parsed.version != "1" && parsed.version != "2")
            return false;

        if (parsed.version == "2")
        {
            if (!RequireField("Provider", parsed.provider))
                return false;
        }
        else
        {
            // Version 1 was GitHub-only.
            parsed.provider = "github";
        }

        // Created by: NeroMorte - Reject unknown durable transaction states
        // before a persisted manifest can ever participate in recovery.
        if (parsed.state != "PREPARED" &&
            parsed.state != "APPLYING" &&
            parsed.state != "COMMITTED" &&
            parsed.state != "ROLLED_BACK" &&
            parsed.state != "ROLLBACK_FAILED")
        {
            return false;
        }

        std::string stageDirectory;
        std::string backupDirectory;
        std::string changeCountText;

        if (!RequireField(
                "StageDirectory",
                stageDirectory) ||
            !RequireField(
                "BackupDirectory",
                backupDirectory) ||
            !RequireField(
                "ChangeCount",
                changeCountText))
        {
            return false;
        }

        size_t parsedCount = 0;

        try
        {
            size_t consumed = 0;

            const unsigned long long count =
                std::stoull(
                    changeCountText,
                    &consumed,
                    10
                );

            if (consumed !=
                changeCountText.size())
            {
                return false;
            }

            parsedCount =
                static_cast<size_t>(count);

            if (static_cast<unsigned long long>(
                    parsedCount) != count)
            {
                return false;
            }
        }
        catch (...)
        {
            return false;
        }

        if (parsedCount > 100000)
            return false;

        parsed.stageDirectory =
            fs::path(stageDirectory);

        parsed.backupDirectory =
            fs::path(backupDirectory);

        parsed.changes.reserve(
            parsedCount
        );

        for (size_t i = 0;
             i < parsedCount;
             ++i)
        {
            const std::string prefix =
                "Change." +
                std::to_string(i) +
                ".";

            std::string livePath;
            std::string backupPath;
            std::string existedBefore;
            std::string transactionState;
            std::string recoveryState;
            std::string backupSHA256;
            std::string expectedSHA256;

            if (!RequireField(
                    prefix + "LivePath",
                    livePath) ||
                !RequireField(
                    prefix + "BackupPath",
                    backupPath) ||
                !RequireField(
                    prefix + "ExistedBefore",
                    existedBefore) ||
                !RequireField(
                    prefix + "TransactionState",
                    transactionState) ||
                !RequireField(
                    prefix + "BackupSHA256",
                    backupSHA256) ||
                !RequireField(
                    prefix + "ExpectedSHA256",
                    expectedSHA256))
            {
                return false;
            }

            // Created by: NeroMorte - RecoveryState is a backward-compatible

            // Version 1 extension. Older Version 1 manifests safely default

            // to NOT_STARTED when the field is absent.

            const std::string recoveryStateKey =

                prefix + "RecoveryState";


            for (const auto& field : fields)

            {

                if (field.first == recoveryStateKey)

                {

                    recoveryState =

                        field.second;


                    break;

                }

            }


            if (recoveryState.empty())

            {

                recoveryState =

                    "NOT_STARTED";

            }


            if (recoveryState != "NOT_STARTED" &&

                recoveryState != "RECOVERY_PENDING" &&

                recoveryState != "RECOVERED_VERIFIED")

            {

                return false;

            }


            if (existedBefore != "0" &&
                existedBefore != "1")
            {
                return false;
            }

            AppliedFileChange change;

            change.livePath =
                fs::path(livePath);

            change.backupPath =
                fs::path(backupPath);

            change.existedBefore =
                existedBefore == "1";

            if (transactionState != "PENDING" &&
                transactionState != "APPLIED_VERIFIED")
            {
                return false;
            }

            change.transactionState =
                transactionState;


            change.recoveryState =
                recoveryState;

            if (expectedSHA256.size() !=
                SHA256_DIGEST_LENGTH * 2 ||
                !std::all_of(
                    expectedSHA256.begin(),
                    expectedSHA256.end(),
                    [](unsigned char ch)
                    {
                        return
                            (ch >= '0' && ch <= '9') ||
                            (ch >= 'a' && ch <= 'f');
                    }))
            {
                return false;
            }

            // Created by: NeroMorte - Existing-file recovery requires
            // durable identity for the exact original backup contents.
            if (change.existedBefore)
            {
                if (backupSHA256.size() !=
                    SHA256_DIGEST_LENGTH * 2 ||
                    !std::all_of(
                        backupSHA256.begin(),
                        backupSHA256.end(),
                        [](unsigned char ch)
                        {
                            return
                                (ch >= '0' && ch <= '9') ||
                                (ch >= 'a' && ch <= 'f');
                        }))
                {
                    return false;
                }
            }
            else if (!backupSHA256.empty())
            {
                return false;
            }

            change.backupSHA256 =
                backupSHA256;

            change.expectedSHA256 =
                expectedSHA256;

            parsed.changes.push_back(
                std::move(change)
            );
        }

        manifest =
            std::move(parsed);

        return true;
    }

    // Created by: NeroMorte - Persist exactly one active Apply
    // transaction pointer without scanning historical backups.
    struct ActiveApplyTransactionRecord
    {
        std::string version = "1";
        fs::path manifestPath;
    };

    // Created by: NeroMorte - Return the fixed recovery record path
    // derived only from the trusted running MQ runtime root.
    fs::path GetActiveApplyTransactionRecordPath(
        const fs::path& runtimeRoot)
    {
        if (runtimeRoot.empty())
            return {};

        return runtimeRoot /
            "webupdate_recovery" /
            "active_transaction.ini";
    }

    // Created by: NeroMorte - Atomically publish the exact manifest
    // selected as the single active Apply transaction.
    bool WriteActiveApplyTransactionRecord(
        const fs::path& runtimeRoot,
        const fs::path& manifestPath)
    {
        if (runtimeRoot.empty() || manifestPath.empty())
            return false;

        const fs::path recordPath =
            GetActiveApplyTransactionRecordPath(runtimeRoot);

        if (recordPath.empty())
            return false;

        const fs::path recoveryDirectory =
            recordPath.parent_path();

        if (recoveryDirectory.empty() ||
            HasReparsePointInPath(
                runtimeRoot,
                recoveryDirectory) ||
            IsReparsePoint(recoveryDirectory))
        {
            return false;
        }

        // Created by: NeroMorte - Establish the fixed recovery directory before publishing
        // the active pointer, then revalidate it so WriteFileBinary cannot silently create
        // a parent after our only reparse check.
        std::error_code ec;

        fs::create_directories(
            recoveryDirectory,
            ec);

        if (ec ||
            HasReparsePointInPath(
                runtimeRoot,
                recoveryDirectory) ||
            IsReparsePoint(recoveryDirectory))
        {
            return false;
        }

        const DWORD recoveryAttributes =
            GetFileAttributesW(
                recoveryDirectory.wstring().c_str());

        if (recoveryAttributes == INVALID_FILE_ATTRIBUTES ||
            (recoveryAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0 ||
            (recoveryAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0)
        {
            return false;
        }

        // Created by: NeroMorte - Fail closed when another active transaction record already exists.
        // An Apply must never replace unresolved recovery evidence from an earlier transaction.
        SetLastError(ERROR_SUCCESS);

        const DWORD recordAttributes =
            GetFileAttributesW(
                recordPath.wstring().c_str());

        if (recordAttributes != INVALID_FILE_ATTRIBUTES)
            return false;

        const DWORD recordError =
            GetLastError();

        if (recordError != ERROR_FILE_NOT_FOUND &&
            recordError != ERROR_PATH_NOT_FOUND)
        {
            return false;
        }

        std::ostringstream stream;
        stream
            << "Version=1\n"
            << "ManifestPath="
            << EscapeApplyManifestValue(manifestPath.string())
            << "\n";

        const std::string data = stream.str();

        fs::path tempPath = recordPath;
        tempPath += ".tmp";

        if (HasReparsePointInPath(runtimeRoot, tempPath) ||
            IsReparsePoint(tempPath))
        {
            return false;
        }

        SetLastError(ERROR_SUCCESS);

        const DWORD tempAttributes =
            GetFileAttributesW(
                tempPath.wstring().c_str());

        if (tempAttributes != INVALID_FILE_ATTRIBUTES)
        {
            if ((tempAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0 ||
                (tempAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0)
            {
                return false;
            }

            ec.clear();

            const bool removedTemp =
                fs::remove(tempPath, ec);

            if (ec || !removedTemp)
                return false;
        }
        else
        {
            const DWORD tempError =
                GetLastError();

            if (tempError != ERROR_FILE_NOT_FOUND &&
                tempError != ERROR_PATH_NOT_FOUND)
            {
                return false;
            }
        }

        if (HasReparsePointInPath(
                runtimeRoot,
                recoveryDirectory) ||
            IsReparsePoint(recoveryDirectory) ||
            HasReparsePointInPath(
                runtimeRoot,
                tempPath) ||
            IsReparsePoint(tempPath))
        {
            return false;
        }

        if (!WriteFileBinary(tempPath, data))
            return false;

        if (HasReparsePointInPath(
                runtimeRoot,
                recoveryDirectory) ||
            IsReparsePoint(recoveryDirectory) ||
            IsReparsePoint(tempPath))
        {
            ec.clear();
            fs::remove(tempPath, ec);
            return false;
        }

        std::string verifyTemp;

        if (!ReadFileBinary(tempPath, verifyTemp) ||
            verifyTemp != data)
        {
            ec.clear();
            fs::remove(tempPath, ec);
            return false;
        }

        // Recheck the final record immediately before publication. We intentionally do
        // not use MOVEFILE_REPLACE_EXISTING here: if a record appeared after the first
        // check, publication fails rather than overwriting recovery evidence.
        SetLastError(ERROR_SUCCESS);

        const DWORD finalRecordAttributes =
            GetFileAttributesW(
                recordPath.wstring().c_str());

        if (finalRecordAttributes != INVALID_FILE_ATTRIBUTES)
        {
            ec.clear();
            fs::remove(tempPath, ec);
            return false;
        }

        const DWORD finalRecordError =
            GetLastError();

        if (finalRecordError != ERROR_FILE_NOT_FOUND &&
            finalRecordError != ERROR_PATH_NOT_FOUND)
        {
            ec.clear();
            fs::remove(tempPath, ec);
            return false;
        }

        if (HasReparsePointInPath(
                runtimeRoot,
                recoveryDirectory) ||
            IsReparsePoint(recoveryDirectory) ||
            IsReparsePoint(tempPath) ||
            IsReparsePoint(recordPath))
        {
            ec.clear();
            fs::remove(tempPath, ec);
            return false;
        }

        if (!MoveFileExW(
                tempPath.wstring().c_str(),
                recordPath.wstring().c_str(),
                MOVEFILE_WRITE_THROUGH))
        {
            ec.clear();
            fs::remove(tempPath, ec);
            return false;
        }

        if (HasReparsePointInPath(
                runtimeRoot,
                recordPath) ||
            IsReparsePoint(recordPath))
        {
            return false;
        }

        std::string verifyLive;

        if (!ReadFileBinary(recordPath, verifyLive) ||
            verifyLive != data)
        {
            return false;
        }

        return true;
    }

    // Created by: NeroMorte - Parse the fixed active transaction
    // record without yet trusting or acting on its manifest path.
    bool ReadActiveApplyTransactionRecord(
        const fs::path& runtimeRoot,
        ActiveApplyTransactionRecord& record)
    {
        record = {};

        const fs::path recordPath =
            GetActiveApplyTransactionRecordPath(runtimeRoot);

        if (recordPath.empty() ||
            HasReparsePointInPath(runtimeRoot, recordPath) ||
            IsReparsePoint(recordPath))
        {
            return false;
        }

        std::string data;

        if (!ReadFileBinary(recordPath, data))
            return false;

        std::istringstream stream(data);
        std::string line;
        std::string version;
        std::string manifestPath;
        bool haveVersion = false;
        bool haveManifestPath = false;

        while (std::getline(stream, line))
        {
            if (!line.empty() && line.back() == '\r')
                line.pop_back();

            const size_t equals = line.find('=');

            if (equals == std::string::npos)
                return false;

            const std::string key = line.substr(0, equals);
            std::string value;

            if (!UnescapeApplyManifestValue(
                    line.substr(equals + 1),
                    value))
            {
                return false;
            }

            if (key == "Version")
            {
                if (haveVersion)
                    return false;

                version = value;
                haveVersion = true;
            }
            else if (key == "ManifestPath")
            {
                if (haveManifestPath)
                    return false;

                manifestPath = value;
                haveManifestPath = true;
            }
            else
            {
                return false;
            }
        }

        if (!haveVersion ||
            !haveManifestPath ||
            version != "1" ||
            manifestPath.empty())
        {
            return false;
        }

        record.version = version;
        record.manifestPath = fs::path(manifestPath);

        return true;
    }

    // Created by: NeroMorte - Clear only the fixed trusted active
    // transaction record after a durable terminal state is proven.
    bool ClearActiveApplyTransactionRecord(
        const fs::path& runtimeRoot)
    {
        if (runtimeRoot.empty())
            return false;

        const fs::path recordPath =
            GetActiveApplyTransactionRecordPath(runtimeRoot);

        if (recordPath.empty() ||
            HasReparsePointInPath(runtimeRoot, recordPath) ||
            IsReparsePoint(recordPath))
        {
            return false;
        }

        // Created by: NeroMorte - Use Win32 attributes so a missing active record is unambiguous.
        // Missing is already clear; any other lookup failure or unsafe object fails closed.
        SetLastError(ERROR_SUCCESS);

        const DWORD attributes =
            GetFileAttributesW(
                recordPath.wstring().c_str());

        if (attributes == INVALID_FILE_ATTRIBUTES)
        {
            const DWORD error =
                GetLastError();

            return
                error == ERROR_FILE_NOT_FOUND ||
                error == ERROR_PATH_NOT_FOUND;
        }

        if ((attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0 ||
            (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0)
        {
            return false;
        }

        std::error_code ec;

        const bool removed =
            fs::remove(recordPath, ec);

        if (ec || !removed)
            return false;

        SetLastError(ERROR_SUCCESS);

        const DWORD afterAttributes =
            GetFileAttributesW(
                recordPath.wstring().c_str());

        if (afterAttributes != INVALID_FILE_ATTRIBUTES)
            return false;

        const DWORD afterError =
            GetLastError();

        return
            afterError == ERROR_FILE_NOT_FOUND ||
            afterError == ERROR_PATH_NOT_FOUND;
    }

    // Created by: NeroMorte - Validate every persisted recovery path
    // against roots derived from the running MacroQuest installation.
    // This validator intentionally does not follow reparse points.
    // Created by: NeroMorte - Compare trusted Windows path identities case-insensitively
    // without requiring either path to exist or following filesystem links.
    bool WindowsPathIdentityEquals(
        const fs::path& leftPath,
        const fs::path& rightPath)
    {
        if (leftPath.empty() || rightPath.empty())
            return false;

        const fs::path left =
            leftPath.lexically_normal();

        const fs::path right =
            rightPath.lexically_normal();

        if (!left.is_absolute() ||
            !right.is_absolute())
        {
            return false;
        }

        const std::wstring leftText =
            left.native();

        const std::wstring rightText =
            right.native();

        if (leftText.size() != rightText.size())
            return false;

        return CompareStringOrdinal(
            leftText.c_str(),
            static_cast<int>(leftText.size()),
            rightText.c_str(),
            static_cast<int>(rightText.size()),
            TRUE) == CSTR_EQUAL;
    }

    // Created by: NeroMorte - Derive persisted live-file suffix using Windows case-insensitive component identity.
    // This avoids std::filesystem lexical-relative case sensitivity while still
    // requiring an exact structural descendant of the trusted root.
    bool TryGetWindowsRelativePath(
        const fs::path& trustedRoot,
        const fs::path& candidatePath,
        fs::path& relativePath)
    {
        relativePath.clear();

        if (trustedRoot.empty() || candidatePath.empty())
            return false;

        const fs::path root =
            trustedRoot.lexically_normal();

        const fs::path candidate =
            candidatePath.lexically_normal();

        if (!root.is_absolute() ||
            !candidate.is_absolute())
        {
            return false;
        }

        auto rootIt = root.begin();
        const auto rootEnd = root.end();
        auto candidateIt = candidate.begin();
        const auto candidateEnd = candidate.end();

        for (; rootIt != rootEnd; ++rootIt, ++candidateIt)
        {
            if (candidateIt == candidateEnd)
                return false;

            const std::wstring rootPart =
                rootIt->native();

            const std::wstring candidatePart =
                candidateIt->native();

            if (CompareStringOrdinal(
                    rootPart.c_str(),
                    static_cast<int>(rootPart.size()),
                    candidatePart.c_str(),
                    static_cast<int>(candidatePart.size()),
                    TRUE) != CSTR_EQUAL)
            {
                return false;
            }
        }

        if (candidateIt == candidateEnd)
            return false;

        fs::path result;

        for (; candidateIt != candidateEnd; ++candidateIt)
        {
            if (*candidateIt == "." ||
                *candidateIt == "..")
            {
                return false;
            }

            result /= *candidateIt;
        }

        if (result.empty() ||
            result.is_absolute())
        {
            return false;
        }

        relativePath =
            result.lexically_normal();

        return !relativePath.empty() &&
               !relativePath.is_absolute();
    }

    // Created by: NeroMorte - Active record must identify the exact persisted manifest.
    // Recovery may only consume BackupDirectory/apply_transaction.ini for the
    // transaction described by that same parsed manifest.
    bool ValidateActiveApplyManifestIdentity(
        const ActiveApplyTransactionRecord& record,
        const ApplyTransactionManifest& manifest)
    {
        if (record.manifestPath.empty() ||
            manifest.backupDirectory.empty())
        {
            return false;
        }

        const fs::path expectedManifestPath =
            manifest.backupDirectory /
            "apply_transaction.ini";

        return WindowsPathIdentityEquals(
            record.manifestPath,
            expectedManifestPath);
    }

    bool ValidateApplyTransactionManifestPaths(
        const ApplyTransactionManifest& manifest,
        const fs::path& runtimeRoot,
        const fs::path& luaDirectory)
    {
        if (runtimeRoot.empty() ||
            luaDirectory.empty() ||
            manifest.remoteSha.empty() ||
            manifest.stageDirectory.empty() ||
            manifest.backupDirectory.empty())
        {
            return false;
        }

        profilemodel::Profile profile;
        std::string profileError;
        if (!SnapshotMainDownloadProfile(profile, profileError))
            return false;

        // Persisted repository and reference must match the current immutable
        // Main Download identity before recovery may touch any live file.
        const std::string expectedRepository =
            profile.owner + "/" + profile.repository;

        if (manifest.repository != expectedRepository ||
            manifest.branch != profile.reference ||
            manifest.profileId != profile.id ||
            manifest.provider != profilemodel::SourceProviderName(profile.provider) ||
            !IsValidGitSha(manifest.remoteSha))
        {
            return false;
        }

        const fs::path trustedStageRoot =
            runtimeRoot /
            "webupdate_stage" /
            profile.id;

        const fs::path trustedBackupRoot =
            runtimeRoot /
            "webupdate_backup" /
            profile.id;

        const fs::path expectedStageDirectory =
            trustedStageRoot /
            manifest.remoteSha;

        const fs::path expectedBackupShaRoot =
            trustedBackupRoot /
            manifest.remoteSha;

        // Created by: NeroMorte - Require exact persisted transaction structure.
        // Stage must be exactly the SHA directory. Backup must be exactly one
        // transaction directory below the same SHA root.
        if (!WindowsPathIdentityEquals(
                manifest.stageDirectory,
                expectedStageDirectory))
        {
            return false;
        }

        const fs::path normalizedBackupDirectory =
            manifest.backupDirectory.lexically_normal();

        const fs::path normalizedBackupShaRoot =
            expectedBackupShaRoot.lexically_normal();

        if (!normalizedBackupDirectory.is_absolute() ||
            !normalizedBackupShaRoot.is_absolute())
        {
            return false;
        }

        const fs::path backupTransactionName =
            normalizedBackupDirectory.filename();

        if (backupTransactionName.empty() ||
            backupTransactionName == "." ||
            backupTransactionName == "..")
        {
            return false;
        }

        const fs::path expectedBackupDirectory =
            normalizedBackupShaRoot /
            backupTransactionName;

        if (!WindowsPathIdentityEquals(
                normalizedBackupDirectory,
                expectedBackupDirectory))
        {
            return false;
        }

        if (HasReparsePointInPath(
                trustedStageRoot,
                manifest.stageDirectory) ||
            HasReparsePointInPath(
                trustedBackupRoot,
                manifest.backupDirectory))
        {
            return false;
        }

        for (const auto& change : manifest.changes)
        {
            if (change.livePath.empty() || IsReparsePoint(change.livePath))
            {
                return false;
            }

            const fs::path normalizedLivePath =
                change.livePath.lexically_normal();

            if (!normalizedLivePath.is_absolute() ||
                !runtimeRoot.lexically_normal().is_absolute())
            {
                return false;
            }

            fs::path relativeLivePath;
            fs::path matchedRoot;
            std::string matchedRootName;
            const profilemodel::DestinationRoot allowedRoots[] = {
                profilemodel::DestinationRoot::Lua,
                profilemodel::DestinationRoot::Macros,
                profilemodel::DestinationRoot::Plugins,
                profilemodel::DestinationRoot::Config,
                profilemodel::DestinationRoot::Resources
            };

            for (const auto root : allowedRoots)
            {
                const fs::path candidateRoot =
                    profilemodel::ResolveDestinationRoot(runtimeRoot, root);
                fs::path candidateRelative;
                if (TryGetWindowsRelativePath(
                        candidateRoot,
                        normalizedLivePath,
                        candidateRelative))
                {
                    matchedRoot = candidateRoot;
                    matchedRootName = profilemodel::DestinationRootName(root);
                    relativeLivePath = candidateRelative;
                    break;
                }
            }

            if (matchedRoot.empty() ||
                HasReparsePointInPath(matchedRoot, normalizedLivePath))
            {
                return false;
            }

            const fs::path expectedLivePath =
                matchedRoot /
                relativeLivePath;

            if (!WindowsPathIdentityEquals(
                    normalizedLivePath,
                    expectedLivePath))
            {
                return false;
            }

            if (change.existedBefore)
            {
                if (change.backupPath.empty() ||
                    HasReparsePointInPath(
                        manifest.backupDirectory,
                        change.backupPath) ||
                    IsReparsePoint(change.backupPath))
                {
                    return false;
                }

                const fs::path expectedBackupPath =
                    normalizedBackupDirectory /
                    matchedRootName /
                    relativeLivePath;

                if (!WindowsPathIdentityEquals(
                        change.backupPath,
                        expectedBackupPath))
                {
                    return false;
                }
            }
            else if (!change.backupPath.empty())
            {
                return false;
            }
        }

        return true;
    }

    // Created by: NeroMorte - Read-only startup recovery detection.
    // This may inspect persisted recovery evidence but must never clear it,
    // rewrite a manifest, rollback files, or otherwise mutate the transaction.
// Created by: NeroMorte - Classify validated persisted recovery evidence without mutating it.
enum class RecoveryDecision
{
    ClearOnly,
    RollbackRequired,
    ManualRequired,
    Refuse
};

// Created by: NeroMorte - Recovery classification is intentionally read-only.
RecoveryDecision ClassifyRecoveryDecisionReadOnly(
    const ApplyTransactionManifest& manifest)
{
    if (manifest.state == "PREPARED")
        return RecoveryDecision::ClearOnly;

    if (manifest.state == "APPLYING")
        return RecoveryDecision::RollbackRequired;

    if (manifest.state == "COMMITTED")
        return RecoveryDecision::ClearOnly;

    if (manifest.state == "ROLLED_BACK")
        return RecoveryDecision::ClearOnly;

    if (manifest.state == "ROLLBACK_FAILED")
        return RecoveryDecision::ManualRequired;

    return RecoveryDecision::Refuse;
}

// Created by: NeroMorte - Stable diagnostic name for the read-only recovery decision.
const char* RecoveryDecisionToString(
    RecoveryDecision decision)
{
    switch (decision)
    {
    case RecoveryDecision::ClearOnly:
        return "CLEAR_ONLY";

    case RecoveryDecision::RollbackRequired:
        return "ROLLBACK_REQUIRED";

    case RecoveryDecision::ManualRequired:
        return "MANUAL_REQUIRED";

    case RecoveryDecision::Refuse:
    default:
        return "REFUSE";
    }
}


// Created by: NeroMorte - Describe the exact read-only action required
// for one persisted APPLYING change without mutating live or recovery evidence.
enum class ApplyingRecoveryFileAction
{
    NoActionOriginal,
    NoActionAbsent,
    RestoreBackup,
    DeleteNewFile,
    Refuse
};

// Created by: NeroMorte - Stable diagnostic name for per-file recovery planning.
const char* ApplyingRecoveryFileActionToString(
    ApplyingRecoveryFileAction action)
{
    switch (action)
    {
    case ApplyingRecoveryFileAction::NoActionOriginal:
        return "NO_ACTION_ORIGINAL";
    case ApplyingRecoveryFileAction::NoActionAbsent:
        return "NO_ACTION_ABSENT";
    case ApplyingRecoveryFileAction::RestoreBackup:
        return "RESTORE_BACKUP";
    case ApplyingRecoveryFileAction::DeleteNewFile:
        return "DELETE_NEW_FILE";
    case ApplyingRecoveryFileAction::Refuse:
    default:
        return "REFUSE";
    }
}

// Created by: NeroMorte - Inspect one persisted APPLYING change and
// classify its current live identity. This function is strictly read-only.
ApplyingRecoveryFileAction PlanApplyingRecoveryFileReadOnly(
    const AppliedFileChange& change,
    const fs::path& trustedRoot)
{
    if (change.livePath.empty() ||
        HasReparsePointInPath(
            trustedRoot,
            change.livePath) ||
        IsReparsePoint(change.livePath))
    {
        return ApplyingRecoveryFileAction::Refuse;
    }

    SetLastError(ERROR_SUCCESS);

    const DWORD liveAttributes =
        GetFileAttributesW(
            change.livePath.wstring().c_str()
        );

    const bool liveAbsent =
        liveAttributes == INVALID_FILE_ATTRIBUTES &&
        (GetLastError() == ERROR_FILE_NOT_FOUND ||
         GetLastError() == ERROR_PATH_NOT_FOUND);

    if (liveAttributes == INVALID_FILE_ATTRIBUTES &&
        !liveAbsent)
    {
        return ApplyingRecoveryFileAction::Refuse;
    }

    if (liveAttributes != INVALID_FILE_ATTRIBUTES &&
        (liveAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0)
    {
        return ApplyingRecoveryFileAction::Refuse;
    }

    if (!change.existedBefore)
    {
        if (liveAbsent)
        {
            // Created by: NeroMorte - During crash-resumable recovery,
            // an absent new file proves the physical delete is complete.
            if (change.recoveryState == "RECOVERY_PENDING" ||
                change.recoveryState == "RECOVERED_VERIFIED")
            {
                return ApplyingRecoveryFileAction::NoActionAbsent;
            }

            if (change.recoveryState != "NOT_STARTED")
                return ApplyingRecoveryFileAction::Refuse;

            if (change.transactionState == "PENDING")
                return ApplyingRecoveryFileAction::NoActionAbsent;

            return ApplyingRecoveryFileAction::Refuse;
        }

        std::string liveData;

        if (!ReadFileBinary(
                change.livePath,
                liveData))
        {
            return ApplyingRecoveryFileAction::Refuse;
        }

        const std::string liveSHA256 =
            ComputeSHA256Hex(liveData);

        if (liveSHA256.empty() ||
            change.expectedSHA256.empty() ||
            liveSHA256 != change.expectedSHA256)
        {
            return ApplyingRecoveryFileAction::Refuse;
        }

        if (change.recoveryState == "RECOVERED_VERIFIED")
            return ApplyingRecoveryFileAction::Refuse;

        if (change.recoveryState == "RECOVERY_PENDING")
            return ApplyingRecoveryFileAction::DeleteNewFile;

        if (change.recoveryState != "NOT_STARTED")
            return ApplyingRecoveryFileAction::Refuse;

        if (change.transactionState == "PENDING" ||
            change.transactionState == "APPLIED_VERIFIED")
        {
            return ApplyingRecoveryFileAction::DeleteNewFile;
        }

        return ApplyingRecoveryFileAction::Refuse;
    }

    if (liveAbsent)
        return ApplyingRecoveryFileAction::Refuse;

    /*
        Created by: NeroMorte - Prove the persisted rollback backup
        itself is a readable regular non-reparse file with the exact
        BackupSHA256 recorded before live mutation. Recovery planning
        remains read-only and fails closed on any backup identity error.
    */
    if (change.backupPath.empty() ||
        change.backupSHA256.empty() ||
        IsReparsePoint(change.backupPath))
    {
        return ApplyingRecoveryFileAction::Refuse;
    }

    SetLastError(ERROR_SUCCESS);

    const DWORD backupAttributes =
        GetFileAttributesW(
            change.backupPath.wstring().c_str()
        );

    if (backupAttributes == INVALID_FILE_ATTRIBUTES ||
        (backupAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0 ||
        (backupAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0)
    {
        return ApplyingRecoveryFileAction::Refuse;
    }

    std::string backupData;

    if (!ReadFileBinary(
            change.backupPath,
            backupData))
    {
        return ApplyingRecoveryFileAction::Refuse;
    }

    const std::string actualBackupSHA256 =
        ComputeSHA256Hex(backupData);

    if (actualBackupSHA256.empty() ||
        actualBackupSHA256 != change.backupSHA256)
    {
        return ApplyingRecoveryFileAction::Refuse;
    }

    std::string liveData;

    if (!ReadFileBinary(
            change.livePath,
            liveData))
    {
        return ApplyingRecoveryFileAction::Refuse;
    }

    const std::string liveSHA256 =
        ComputeSHA256Hex(liveData);

    if (liveSHA256.empty() ||
        change.backupSHA256.empty() ||
        change.expectedSHA256.empty())
    {
        return ApplyingRecoveryFileAction::Refuse;
    }

    // Created by: NeroMorte - Recovery progress is interpreted before
    // Apply progress so a crash during recovery can resume idempotently.
    if (change.recoveryState == "RECOVERED_VERIFIED")
    {
        if (liveSHA256 == change.backupSHA256)
            return ApplyingRecoveryFileAction::NoActionOriginal;

        return ApplyingRecoveryFileAction::Refuse;
    }

    if (change.recoveryState == "RECOVERY_PENDING")
    {
        if (liveSHA256 == change.backupSHA256)
            return ApplyingRecoveryFileAction::NoActionOriginal;

        if (liveSHA256 == change.expectedSHA256)
            return ApplyingRecoveryFileAction::RestoreBackup;

        return ApplyingRecoveryFileAction::Refuse;
    }

    if (change.recoveryState != "NOT_STARTED")
        return ApplyingRecoveryFileAction::Refuse;

    if (change.transactionState == "PENDING")
    {
        if (liveSHA256 == change.backupSHA256)
            return ApplyingRecoveryFileAction::NoActionOriginal;

        if (liveSHA256 == change.expectedSHA256)
            return ApplyingRecoveryFileAction::RestoreBackup;

        return ApplyingRecoveryFileAction::Refuse;
    }

    if (change.transactionState == "APPLIED_VERIFIED")
    {
        if (liveSHA256 == change.expectedSHA256)
            return ApplyingRecoveryFileAction::RestoreBackup;

        return ApplyingRecoveryFileAction::Refuse;
    }

    return ApplyingRecoveryFileAction::Refuse;
}

// Created by: NeroMorte - Build and report an APPLYING recovery plan
// without restoring, deleting, rewriting, or clearing any persisted evidence.
bool PlanApplyingRecoveryReadOnly(
    const ApplyTransactionManifest& manifest,
    const fs::path& trustedRoot)
{
    if (manifest.state != "APPLYING")
        return false;

    bool safePlan = true;

    for (size_t i = 0;
         i < manifest.changes.size();
         ++i)
    {
        const AppliedFileChange& change =
            manifest.changes[i];

        const ApplyingRecoveryFileAction action =
            PlanApplyingRecoveryFileReadOnly(
                change,
                trustedRoot
            );

        WriteChatf(
            "\ay[MQ2WebUpdate]\ax Recovery plan [%zu]: %s -> %s",
            i,
            change.livePath.string().c_str(),
            ApplyingRecoveryFileActionToString(action)
        );

        if (action == ApplyingRecoveryFileAction::Refuse)
            safePlan = false;
    }

    WriteChatf(
        safePlan
            ? "\ag[MQ2WebUpdate]\ax APPLYING recovery plan is fully classified and remains read-only."
            : "\ar[MQ2WebUpdate]\ax APPLYING recovery plan contains REFUSE entries; automatic recovery must remain blocked."
    );

    return safePlan;
}

// Created by: NeroMorte - Immutable read-only APPLYING recovery plan snapshot.
// This foundation records the exact classification observed during planning
// so a future executor can require a complete second validation before mutation.
struct ApplyingRecoveryPlanEntry
{
    AppliedFileChange change;
    ApplyingRecoveryFileAction action = ApplyingRecoveryFileAction::Refuse;
};

// Created by: NeroMorte - Whole-transaction recovery plan captured before
// any future recovery mutation is permitted.
struct ApplyingRecoveryPlanSnapshot
{
    std::vector<ApplyingRecoveryPlanEntry> entries;
};

// Created by: NeroMorte - Build an immutable APPLYING recovery plan without
// restoring, deleting, rewriting, clearing, or otherwise mutating evidence.
// Created by: NeroMorte - Persist one crash-resumable recovery-progress
// transition and prove the exact manifest state was durably readable before
// any future recovery executor is allowed to continue.
bool PersistApplyingRecoveryProgress(
    const fs::path& manifestPath,
    ApplyTransactionManifest& manifest,
    const size_t changeIndex,
    const std::string& expectedCurrentState,
    const std::string& nextState)
{
    if (manifestPath.empty() ||
        manifest.state != "APPLYING" ||
        changeIndex >= manifest.changes.size())
    {
        return false;
    }

    if ((expectedCurrentState != "NOT_STARTED" &&
         expectedCurrentState != "RECOVERY_PENDING") ||
        (nextState != "RECOVERY_PENDING" &&
         nextState != "RECOVERED_VERIFIED"))
    {
        return false;
    }

    if ((expectedCurrentState == "NOT_STARTED" &&
         nextState != "RECOVERY_PENDING") ||
        (expectedCurrentState == "RECOVERY_PENDING" &&
         nextState != "RECOVERED_VERIFIED"))
    {
        return false;
    }

    AppliedFileChange& change =
        manifest.changes[changeIndex];

    if (change.recoveryState != expectedCurrentState)
        return false;

    const std::string previousState =
        change.recoveryState;

    change.recoveryState =
        nextState;

    if (!WriteApplyTransactionManifest(
            manifestPath,
            manifest))
    {
        change.recoveryState =
            previousState;

        return false;
    }

    ApplyTransactionManifest persistedManifest;

    if (!ReadApplyTransactionManifest(
            manifestPath,
            persistedManifest))
    {
        // Created by: NeroMorte - The write may already be durable.
        // Never guess or continue from the caller's in-memory manifest.
        manifest = {};
        return false;
    }

    if (persistedManifest.state != "APPLYING" ||
        persistedManifest.changes.size() != manifest.changes.size() ||
        changeIndex >= persistedManifest.changes.size())
    {
        manifest = {};
        return false;
    }

    const AppliedFileChange& persistedChange =
        persistedManifest.changes[changeIndex];

    if (!WindowsPathIdentityEquals(
            persistedChange.livePath,
            change.livePath) ||
        // Created by: NeroMorte - ExistedBefore=false intentionally has no backup path.
        (change.existedBefore
            ? !WindowsPathIdentityEquals(
                persistedChange.backupPath,
                change.backupPath)
            : (!persistedChange.backupPath.empty() ||
               !change.backupPath.empty())) ||
        persistedChange.existedBefore != change.existedBefore ||
        persistedChange.transactionState != change.transactionState ||
        persistedChange.recoveryState != nextState ||
        persistedChange.backupSHA256 != change.backupSHA256 ||
        persistedChange.expectedSHA256 != change.expectedSHA256)
    {
        manifest = {};
        return false;
    }

    // Created by: NeroMorte - Continue only from the independently
    // reread durable manifest, never merely from the object we attempted to write.
    manifest = std::move(persistedManifest);

    return true;
}

// Created by: NeroMorte - Execute one already-durable RECOVERY_PENDING
// physical recovery operation. This helper never advances manifest state;
// its caller must persist RECOVERED_VERIFIED only after this returns true.
bool ExecuteApplyingRecoveryFilePending(
    const AppliedFileChange& change,
    const fs::path& trustedLiveRoot,
    const fs::path& trustedBackupRoot)
{
    if (trustedLiveRoot.empty() ||
        trustedBackupRoot.empty() ||
        change.livePath.empty() ||
        change.recoveryState != "RECOVERY_PENDING" ||
        change.expectedSHA256.empty())
    {
        return false;
    }

    if (HasReparsePointInPath(
            trustedLiveRoot,
            change.livePath) ||
        IsReparsePoint(change.livePath))
    {
        return false;
    }

    const DWORD liveAttributes =
        GetFileAttributesW(
            change.livePath.c_str());

    const DWORD liveAttributeError =
        liveAttributes == INVALID_FILE_ATTRIBUTES
            ? GetLastError()
            : ERROR_SUCCESS;

    const bool liveAbsent =
        liveAttributes == INVALID_FILE_ATTRIBUTES &&
        (liveAttributeError == ERROR_FILE_NOT_FOUND ||
         liveAttributeError == ERROR_PATH_NOT_FOUND);

    if (liveAttributes == INVALID_FILE_ATTRIBUTES &&
        !liveAbsent)
    {
        return false;
    }

    if (!liveAbsent &&
        (liveAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0)
    {
        return false;
    }

    if (!change.existedBefore)
    {
        if (liveAbsent)
            return true;

        std::string liveData;

        if (!ReadFileBinary(
                change.livePath,
                liveData))
        {
            return false;
        }

        const std::string liveSHA256 =
            ComputeSHA256Hex(liveData);

        if (liveSHA256.empty() ||
            liveSHA256 != change.expectedSHA256)
        {
            return false;
        }

        std::error_code removeError;

        if (!fs::remove(
                change.livePath,
                removeError) ||
            removeError)
        {
            return false;
        }

        const DWORD afterDeleteAttributes =
            GetFileAttributesW(
                change.livePath.c_str());

        if (afterDeleteAttributes != INVALID_FILE_ATTRIBUTES)
            return false;

        const DWORD afterDeleteError =
            GetLastError();

        if (afterDeleteError != ERROR_FILE_NOT_FOUND &&
            afterDeleteError != ERROR_PATH_NOT_FOUND)
        {
            return false;
        }

        return true;
    }

    if (change.backupPath.empty() ||
        change.backupSHA256.empty() ||
        HasReparsePointInPath(
            trustedBackupRoot,
            change.backupPath) ||
        IsReparsePoint(change.backupPath))
    {
        return false;
    }

    const DWORD backupAttributes =
        GetFileAttributesW(
            change.backupPath.c_str());

    if (backupAttributes == INVALID_FILE_ATTRIBUTES ||
        (backupAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0 ||
        (backupAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0)
    {
        return false;
    }

    std::string backupData;

    if (!ReadFileBinary(
            change.backupPath,
            backupData))
    {
        return false;
    }

    const std::string actualBackupSHA256 =
        ComputeSHA256Hex(backupData);

    if (actualBackupSHA256.empty() ||
        actualBackupSHA256 != change.backupSHA256)
    {
        return false;
    }

    if (liveAbsent)
        return false;

    std::string liveData;

    if (!ReadFileBinary(
            change.livePath,
            liveData))
    {
        return false;
    }

    const std::string liveSHA256 =
        ComputeSHA256Hex(liveData);

    if (liveSHA256.empty())
        return false;

    // Created by: NeroMorte - A crash may have occurred after physical
    // restoration but before RECOVERED_VERIFIED became durable.
    if (liveSHA256 == change.backupSHA256)
        return true;

    if (liveSHA256 != change.expectedSHA256)
        return false;

    const fs::path tempPath =
        change.livePath.string() +
        ".mq2webupdate-recovery.tmp";

    if (HasReparsePointInPath(
            trustedLiveRoot,
            tempPath) ||
        IsReparsePoint(tempPath))
    {
        return false;
    }

    std::error_code tempError;

    if (fs::exists(tempPath, tempError))
    {
        if (tempError ||
            IsReparsePoint(tempPath) ||
            fs::is_directory(tempPath, tempError) ||
            tempError)
        {
            return false;
        }

        fs::remove(
            tempPath,
            tempError);

        if (tempError)
            return false;
    }
    else if (tempError)
    {
        return false;
    }

    if (!WriteFileBinary(
            tempPath,
            backupData))
    {
        return false;
    }

    std::string tempData;

    if (!ReadFileBinary(
            tempPath,
            tempData) ||
        ComputeSHA256Hex(tempData) != change.backupSHA256)
    {
        std::error_code cleanupError;
        fs::remove(tempPath, cleanupError);
        return false;
    }

    if (HasReparsePointInPath(
            trustedLiveRoot,
            change.livePath) ||
        IsReparsePoint(change.livePath) ||
        HasReparsePointInPath(
            trustedLiveRoot,
            tempPath) ||
        IsReparsePoint(tempPath))
    {
        std::error_code cleanupError;
        fs::remove(tempPath, cleanupError);
        return false;
    }

    // Created by: NeroMorte - Final TOCTOU content guard immediately
    // before replacing the live file.
    std::string finalLiveData;

    if (!ReadFileBinary(
            change.livePath,
            finalLiveData) ||
        ComputeSHA256Hex(finalLiveData) != change.expectedSHA256)
    {
        std::error_code cleanupError;
        fs::remove(tempPath, cleanupError);
        return false;
    }

    if (!MoveFileExW(
            tempPath.c_str(),
            change.livePath.c_str(),
            MOVEFILE_REPLACE_EXISTING |
            MOVEFILE_WRITE_THROUGH))
    {
        std::error_code cleanupError;
        fs::remove(tempPath, cleanupError);
        return false;
    }

    if (HasReparsePointInPath(
            trustedLiveRoot,
            change.livePath) ||
        IsReparsePoint(change.livePath))
    {
        return false;
    }

    std::string restoredData;

    if (!ReadFileBinary(
            change.livePath,
            restoredData))
    {
        return false;
    }

    const std::string restoredSHA256 =
        ComputeSHA256Hex(restoredData);

    if (restoredSHA256.empty() ||
        restoredSHA256 != change.backupSHA256)
    {
        return false;
    }

    return true;
}

bool BuildApplyingRecoveryPlanSnapshotReadOnly(
    const ApplyTransactionManifest& manifest,
    const fs::path& trustedRoot,
    ApplyingRecoveryPlanSnapshot& snapshot)
{
    snapshot.entries.clear();

    if (manifest.state != "APPLYING")
        return false;

    snapshot.entries.reserve(manifest.changes.size());

    bool safePlan = true;

    for (const auto& change : manifest.changes)
    {
        ApplyingRecoveryPlanEntry entry;
        entry.change = change;
        entry.action =
            PlanApplyingRecoveryFileReadOnly(
                entry.change,
                trustedRoot
            );

        if (entry.action == ApplyingRecoveryFileAction::Refuse)
            safePlan = false;

        snapshot.entries.push_back(std::move(entry));
    }

    if (snapshot.entries.size() != manifest.changes.size())
        return false;

    return safePlan;
}

// Created by: NeroMorte - Reclassify every immutable recovery-plan entry
// immediately before any future executor is allowed to mutate live files.
// Any identity drift or REFUSE result invalidates the entire plan.
bool RevalidateApplyingRecoveryPlanSnapshotReadOnly(
    const ApplyTransactionManifest& manifest,
    const fs::path& trustedRoot,
    const ApplyingRecoveryPlanSnapshot& snapshot)
{
    if (manifest.state != "APPLYING" ||
        snapshot.entries.size() != manifest.changes.size())
    {
        return false;
    }

    for (size_t i = 0; i < snapshot.entries.size(); ++i)
    {
        const ApplyingRecoveryPlanEntry& entry =
            snapshot.entries[i];

        const AppliedFileChange& persistedChange =
            manifest.changes[i];

        if (!WindowsPathIdentityEquals(
                entry.change.livePath,
                persistedChange.livePath) ||
            // Created by: NeroMorte - ExistedBefore=false requires both backup paths to stay empty.
            (entry.change.existedBefore
                ? !WindowsPathIdentityEquals(
                    entry.change.backupPath,
                    persistedChange.backupPath)
                : (!entry.change.backupPath.empty() ||
                   !persistedChange.backupPath.empty())) ||
            entry.change.existedBefore != persistedChange.existedBefore ||
            entry.change.transactionState != persistedChange.transactionState ||
            entry.change.recoveryState != persistedChange.recoveryState ||
            entry.change.backupSHA256 != persistedChange.backupSHA256 ||
            entry.change.expectedSHA256 != persistedChange.expectedSHA256)
        {
            return false;
        }

        const ApplyingRecoveryFileAction currentAction =
            PlanApplyingRecoveryFileReadOnly(
                entry.change,
                trustedRoot
            );

        if (currentAction == ApplyingRecoveryFileAction::Refuse ||
            currentAction != entry.action)
        {
            return false;
        }
    }

    return true;
}


    // Created by: NeroMorte - Production crash-resumable APPLYING recovery
// executor. Startup invokes it only after the complete persisted identity,
// trusted paths, and immutable recovery plan have been proven safe.
bool ExecuteInterruptedApplyingTransaction(
    const fs::path& runtimeRoot,
    const fs::path& luaDirectory)
{
    if (runtimeRoot.empty() ||
        luaDirectory.empty())
    {
        return false;
    }

    ActiveApplyTransactionRecord activeRecord;

    if (!ReadActiveApplyTransactionRecord(
            runtimeRoot,
            activeRecord))
    {
        return false;
    }

    if (activeRecord.manifestPath.empty())
        return false;

    ApplyTransactionManifest manifest;

    if (!ReadApplyTransactionManifest(
            activeRecord.manifestPath,
            manifest))
    {
        return false;
    }

    if (manifest.state != "APPLYING" ||
        !ValidateActiveApplyManifestIdentity(
            activeRecord,
            manifest) ||
        !ValidateApplyTransactionManifestPaths(
            manifest,
            runtimeRoot,
            luaDirectory))
    {
        return false;
    }

    ApplyingRecoveryPlanSnapshot initialPlan;

    if (!BuildApplyingRecoveryPlanSnapshotReadOnly(
            manifest,
            luaDirectory,
            initialPlan))
    {
        return false;
    }

    // Created by: NeroMorte - Whole-plan revalidation is the final
    // transaction-wide gate before the first recovery progress mutation.
    if (!RevalidateApplyingRecoveryPlanSnapshotReadOnly(
            manifest,
            luaDirectory,
            initialPlan))
    {
        return false;
    }

    for (size_t i = 0; i < manifest.changes.size(); ++i)
    {
        if (manifest.state != "APPLYING" ||
            i >= manifest.changes.size())
        {
            return false;
        }

        AppliedFileChange& change =
            manifest.changes[i];

        if (change.recoveryState == "RECOVERED_VERIFIED")
        {
            const ApplyingRecoveryFileAction verifiedAction =
                PlanApplyingRecoveryFileReadOnly(
                    change,
                    luaDirectory
                );

            if (verifiedAction != ApplyingRecoveryFileAction::NoActionOriginal &&
                verifiedAction != ApplyingRecoveryFileAction::NoActionAbsent)
            {
                return false;
            }

            continue;
        }

        if (change.recoveryState == "NOT_STARTED")
        {
            const ApplyingRecoveryFileAction beforePendingAction =
                PlanApplyingRecoveryFileReadOnly(
                    change,
                    luaDirectory
                );

            if (beforePendingAction == ApplyingRecoveryFileAction::Refuse)
                return false;

            if (!PersistApplyingRecoveryProgress(
                    activeRecord.manifestPath,
                    manifest,
                    i,
                    "NOT_STARTED",
                    "RECOVERY_PENDING"))
            {
                // Created by: NeroMorte - The manifest write may already
                // be durable. Stop immediately and require a fresh recovery
                // attempt to reread the active transaction from disk.
                return false;
            }
        }
        else if (change.recoveryState != "RECOVERY_PENDING")
        {
            return false;
        }

        if (i >= manifest.changes.size() ||
            manifest.state != "APPLYING")
        {
            return false;
        }

        AppliedFileChange& pendingChange =
            manifest.changes[i];

        if (pendingChange.recoveryState != "RECOVERY_PENDING")
            return false;

        // Created by: NeroMorte - Reclassify from the independently
        // reread durable RECOVERY_PENDING manifest before physical mutation.
        const ApplyingRecoveryFileAction pendingAction =
            PlanApplyingRecoveryFileReadOnly(
                pendingChange,
                luaDirectory
            );

        if (pendingAction == ApplyingRecoveryFileAction::Refuse)
            return false;

        if (pendingAction == ApplyingRecoveryFileAction::RestoreBackup ||
            pendingAction == ApplyingRecoveryFileAction::DeleteNewFile)
        {
            if (!ExecuteApplyingRecoveryFilePending(
                    pendingChange,
                    luaDirectory,
                    manifest.backupDirectory))
            {
                return false;
            }
        }
        else if (pendingAction != ApplyingRecoveryFileAction::NoActionOriginal &&
                 pendingAction != ApplyingRecoveryFileAction::NoActionAbsent)
        {
            return false;
        }

        // Created by: NeroMorte - Physical recovery must independently
        // classify as the recovered state before progress can advance.
        const ApplyingRecoveryFileAction afterPhysicalAction =
            PlanApplyingRecoveryFileReadOnly(
                pendingChange,
                luaDirectory
            );

        if (afterPhysicalAction != ApplyingRecoveryFileAction::NoActionOriginal &&
            afterPhysicalAction != ApplyingRecoveryFileAction::NoActionAbsent)
        {
            return false;
        }

        if (!PersistApplyingRecoveryProgress(
                activeRecord.manifestPath,
                manifest,
                i,
                "RECOVERY_PENDING",
                "RECOVERED_VERIFIED"))
        {
            // Created by: NeroMorte - Physical recovery may already be
            // complete while durable progress remains RECOVERY_PENDING.
            // Stop; the next fresh recovery attempt will resume idempotently.
            return false;
        }
    }

    if (manifest.state != "APPLYING")
        return false;

    // Created by: NeroMorte - Do not mark the whole transaction rolled
    // back until every persisted entry and every physical live state proves
    // recovery complete.
    for (size_t i = 0; i < manifest.changes.size(); ++i)
    {
        const AppliedFileChange& change =
            manifest.changes[i];

        if (change.recoveryState != "RECOVERED_VERIFIED")
            return false;

        const ApplyingRecoveryFileAction finalAction =
            PlanApplyingRecoveryFileReadOnly(
                change,
                luaDirectory
            );

        if (finalAction != ApplyingRecoveryFileAction::NoActionOriginal &&
            finalAction != ApplyingRecoveryFileAction::NoActionAbsent)
        {
            return false;
        }
    }

    // Created by: NeroMorte - Re-read the exact active record immediately
    // before the terminal manifest transition so identity drift cannot cause
    // another transaction's evidence to be cleared.
    ActiveApplyTransactionRecord finalActiveRecord;

    if (!ReadActiveApplyTransactionRecord(
            runtimeRoot,
            finalActiveRecord))
    {
        return false;
    }

    ApplyTransactionManifest finalManifest;

    if (!ReadApplyTransactionManifest(
            finalActiveRecord.manifestPath,
            finalManifest))
    {
        return false;
    }

    if (finalManifest.state != "APPLYING" ||
        !WindowsPathIdentityEquals(
            finalActiveRecord.manifestPath,
            activeRecord.manifestPath) ||
        !ValidateActiveApplyManifestIdentity(
            finalActiveRecord,
            finalManifest) ||
        !ValidateApplyTransactionManifestPaths(
            finalManifest,
            runtimeRoot,
            luaDirectory) ||
        finalManifest.changes.size() != manifest.changes.size())
    {
        return false;
    }

    for (size_t i = 0; i < finalManifest.changes.size(); ++i)
    {
        const AppliedFileChange& finalChange =
            finalManifest.changes[i];

        if (finalChange.recoveryState != "RECOVERED_VERIFIED")
            return false;

        const ApplyingRecoveryFileAction finalAction =
            PlanApplyingRecoveryFileReadOnly(
                finalChange,
                luaDirectory
            );

        if (finalAction != ApplyingRecoveryFileAction::NoActionOriginal &&
            finalAction != ApplyingRecoveryFileAction::NoActionAbsent)
        {
            return false;
        }
    }

    finalManifest.state = "ROLLED_BACK";

    if (!WriteApplyTransactionManifest(
            finalActiveRecord.manifestPath,
            finalManifest))
    {
        return false;
    }

    // Created by: NeroMorte - Independently prove ROLLED_BACK is durable
    // before the active recovery pointer may be removed.
    ApplyTransactionManifest persistedRolledBack;

    if (!ReadApplyTransactionManifest(
            finalActiveRecord.manifestPath,
            persistedRolledBack))
    {
        return false;
    }

    if (persistedRolledBack.state != "ROLLED_BACK" ||
        !ValidateActiveApplyManifestIdentity(
            finalActiveRecord,
            persistedRolledBack) ||
        !ValidateApplyTransactionManifestPaths(
            persistedRolledBack,
            runtimeRoot,
            luaDirectory) ||
        persistedRolledBack.changes.size() != finalManifest.changes.size())
    {
        return false;
    }

    for (size_t i = 0; i < persistedRolledBack.changes.size(); ++i)
    {
        const AppliedFileChange& change =
            persistedRolledBack.changes[i];

        if (change.recoveryState != "RECOVERED_VERIFIED")
            return false;

        const ApplyingRecoveryFileAction finalAction =
            PlanApplyingRecoveryFileReadOnly(
                change,
                luaDirectory
            );

        if (finalAction != ApplyingRecoveryFileAction::NoActionOriginal &&
            finalAction != ApplyingRecoveryFileAction::NoActionAbsent)
        {
            return false;
        }
    }

    if (!ClearActiveApplyTransactionRecord(runtimeRoot))
    {
        // Created by: NeroMorte - ROLLED_BACK is already durable.
        // Retain the active record if clearing it cannot be proven safe.
        return false;
    }

    return true;
}

// Created by: NeroMorte - Prove that one file matches the physical state
// required before a stale active pointer may be cleared for a terminal or
// pre-mutation transaction state.
bool VerifyClearOnlyFileStateReadOnly(
    const AppliedFileChange& change,
    const std::string& manifestState,
    const fs::path& luaDirectory)
{
    const ApplyingRecoveryFileAction action =
        PlanApplyingRecoveryFileReadOnly(
            change,
            luaDirectory
        );

    if (manifestState == "PREPARED")
    {
        return
            change.transactionState == "PENDING" &&
            change.recoveryState == "NOT_STARTED" &&
            (action == ApplyingRecoveryFileAction::NoActionOriginal ||
             action == ApplyingRecoveryFileAction::NoActionAbsent);
    }

    if (manifestState == "COMMITTED")
    {
        return
            change.transactionState == "APPLIED_VERIFIED" &&
            change.recoveryState == "NOT_STARTED" &&
            (action == ApplyingRecoveryFileAction::RestoreBackup ||
             action == ApplyingRecoveryFileAction::DeleteNewFile);
    }

    if (manifestState == "ROLLED_BACK")
    {
        return
            change.recoveryState == "RECOVERED_VERIFIED" &&
            (action == ApplyingRecoveryFileAction::NoActionOriginal ||
             action == ApplyingRecoveryFileAction::NoActionAbsent);
    }

    return false;
}

// Created by: NeroMorte - Production CLEAR_ONLY recovery executor for crash
// boundaries where PREPARED, COMMITTED, or ROLLED_BACK is durable but the
// active pointer survived. Every state is physically re-proven before clear.
bool ExecuteInterruptedClearOnlyTransaction(
    const fs::path& runtimeRoot,
    const fs::path& luaDirectory)
{
    if (runtimeRoot.empty() ||
        luaDirectory.empty())
    {
        return false;
    }

    ActiveApplyTransactionRecord activeRecord;

    if (!ReadActiveApplyTransactionRecord(
            runtimeRoot,
            activeRecord))
    {
        return false;
    }

    if (activeRecord.manifestPath.empty())
        return false;

    ApplyTransactionManifest manifest;

    if (!ReadApplyTransactionManifest(
            activeRecord.manifestPath,
            manifest))
    {
        return false;
    }

    // Created by: NeroMorte - Accept only states classified CLEAR_ONLY,
    // then prove each state's distinct durable and physical invariants.
    if ((manifest.state != "PREPARED" &&
         manifest.state != "COMMITTED" &&
         manifest.state != "ROLLED_BACK") ||
        !ValidateActiveApplyManifestIdentity(
            activeRecord,
            manifest) ||
        !ValidateApplyTransactionManifestPaths(
            manifest,
            runtimeRoot,
            luaDirectory))
    {
        return false;
    }

    const std::string expectedState =
        manifest.state;

    // Created by: NeroMorte - Never clear recovery evidence unless every
    // entry independently proves the exact physical state required by the
    // durable transaction state.
    for (size_t i = 0; i < manifest.changes.size(); ++i)
    {
        const AppliedFileChange& change =
            manifest.changes[i];

        if (!VerifyClearOnlyFileStateReadOnly(
                change,
                expectedState,
                luaDirectory))
        {
            return false;
        }
    }

    // Created by: NeroMorte - Re-read both records immediately before
    // clearing the active pointer so identity drift cannot cause another
    // transaction's recovery record to be removed.
    ActiveApplyTransactionRecord finalActiveRecord;

    if (!ReadActiveApplyTransactionRecord(
            runtimeRoot,
            finalActiveRecord))
    {
        return false;
    }

    if (!WindowsPathIdentityEquals(
            finalActiveRecord.manifestPath,
            activeRecord.manifestPath))
    {
        return false;
    }

    ApplyTransactionManifest finalManifest;

    if (!ReadApplyTransactionManifest(
            finalActiveRecord.manifestPath,
            finalManifest))
    {
        return false;
    }

    if (finalManifest.state != expectedState ||
        !ValidateActiveApplyManifestIdentity(
            finalActiveRecord,
            finalManifest) ||
        !ValidateApplyTransactionManifestPaths(
            finalManifest,
            runtimeRoot,
            luaDirectory) ||
        finalManifest.changes.size() != manifest.changes.size())
    {
        return false;
    }

    for (size_t i = 0; i < finalManifest.changes.size(); ++i)
    {
        const AppliedFileChange& change =
            finalManifest.changes[i];

        if (!VerifyClearOnlyFileStateReadOnly(
                change,
                expectedState,
                luaDirectory))
        {
            return false;
        }
    }

    // Created by: NeroMorte - The durable state and every corresponding
    // physical file state have now been independently re-proven. Only the
    // stale active pointer may be removed; all other evidence remains untouched.
    return ClearActiveApplyTransactionRecord(runtimeRoot);
}

void RecoverInterruptedApplyTransactionAtStartup()
{
    // Created by: NeroMorte - Derive every trusted recovery root from
    // the running MacroQuest installation before consuming evidence.
    const fs::path luaDirectory =
        GetRuntimeLuaDirectory();

    if (luaDirectory.empty())
    {
        WriteChatf(
            "\ar[MQ2WebUpdate]\ax Automatic recovery could not locate the MQ2 runtime Lua directory."
        );
        return;
    }

    const fs::path runtimeRoot =
        luaDirectory.parent_path();

    if (runtimeRoot.empty())
    {
        WriteChatf(
            "\ar[MQ2WebUpdate]\ax Automatic recovery could not determine the MQ2 runtime root."
        );
        return;
    }

    const fs::path activeRecordPath =
        GetActiveApplyTransactionRecordPath(runtimeRoot);

    SetLastError(ERROR_SUCCESS);

    const DWORD activeAttributes =
        GetFileAttributesW(
            activeRecordPath.wstring().c_str()
        );

    if (activeAttributes == INVALID_FILE_ATTRIBUTES)
    {
        const DWORD activeError =
            GetLastError();

        if (activeError == ERROR_FILE_NOT_FOUND ||
            activeError == ERROR_PATH_NOT_FOUND)
        {
            return;
        }

        WriteChatf(
            "\ar[MQ2WebUpdate]\ax Automatic recovery could not inspect the active transaction record."
        );
        return;
    }

    if ((activeAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0 ||
        (activeAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0)
    {
        WriteChatf(
            "\ar[MQ2WebUpdate]\ax Recovery evidence is unsafe: active transaction record is not a regular file."
        );
        return;
    }

    ActiveApplyTransactionRecord activeRecord;

    if (!ReadActiveApplyTransactionRecord(
            runtimeRoot,
            activeRecord))
    {
        WriteChatf(
            "\ar[MQ2WebUpdate]\ax Recovery evidence exists but the active transaction record is invalid or unreadable."
        );
        return;
    }

    ApplyTransactionManifest manifest;

    if (!ReadApplyTransactionManifest(
            activeRecord.manifestPath,
            manifest))
    {
        WriteChatf(
            "\ar[MQ2WebUpdate]\ax Recovery evidence exists but the persisted transaction manifest is invalid or unreadable."
        );
        return;
    }

    if (!ValidateActiveApplyManifestIdentity(
            activeRecord,
            manifest))
    {
        WriteChatf(
            "\ar[MQ2WebUpdate]\ax Recovery evidence rejected: active record does not identify the exact persisted transaction manifest."
        );
        return;
    }

    if (!ValidateApplyTransactionManifestPaths(
            manifest,
            runtimeRoot,
            luaDirectory))
    {
        WriteChatf(
            "\ar[MQ2WebUpdate]\ax Recovery evidence rejected: persisted transaction identity or paths failed validation."
        );
        return;
    }

    const RecoveryDecision recoveryDecision =
        ClassifyRecoveryDecisionReadOnly(manifest);

    WriteChatf(
        "\ay[MQ2WebUpdate]\ax Interrupted apply transaction detected (state: %s, decision: %s).",
        manifest.state.c_str(),
        RecoveryDecisionToString(recoveryDecision)
    );

    bool recoveryAttempted = false;
    bool recoverySucceeded = false;

    if (recoveryDecision == RecoveryDecision::RollbackRequired)
    {
        // Created by: NeroMorte - Report and prove the entire immutable
        // recovery plan before the executor may persist recovery progress.
        if (!PlanApplyingRecoveryReadOnly(
                manifest,
                luaDirectory))
        {
            WriteChatf(
                "\ar[MQ2WebUpdate]\ax Automatic rollback refused because the complete recovery plan could not be proven safe. Evidence was retained."
            );
            return;
        }

        recoveryAttempted = true;
        recoverySucceeded =
            ExecuteInterruptedApplyingTransaction(
                runtimeRoot,
                luaDirectory
            );
    }
    else if (recoveryDecision == RecoveryDecision::ClearOnly)
    {
        recoveryAttempted = true;
        recoverySucceeded =
            ExecuteInterruptedClearOnlyTransaction(
                runtimeRoot,
                luaDirectory
            );
    }
    else if (recoveryDecision == RecoveryDecision::ManualRequired)
    {
        WriteChatf(
            "\ar[MQ2WebUpdate]\ax Automatic recovery requires manual review. Recovery evidence was retained."
        );
        return;
    }
    else
    {
        WriteChatf(
            "\ar[MQ2WebUpdate]\ax Automatic recovery refused the persisted transaction. Recovery evidence was retained."
        );
        return;
    }

    if (!recoveryAttempted)
        return;

    if (recoverySucceeded)
    {
        WriteChatf(
            "\ag[MQ2WebUpdate]\ax Automatic recovery completed successfully. The stale active transaction pointer was cleared."
        );
    }
    else
    {
        WriteChatf(
            "\ar[MQ2WebUpdate]\ax Automatic recovery failed safely. Recovery evidence was retained for the next startup or manual review."
        );
    }
}

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

    // Created by: NeroMorte - Roll back only when the destination
    // object can be proven safe for the corresponding transaction.
    bool RollbackAppliedFiles(
        const std::vector<AppliedFileChange>& applied,
        const fs::path& trustedRoot)
    {
        WriteChatf(
            "\ar[MQ2WebUpdate]\ax Rolling back applied files..."
        );

        bool rollbackSucceeded = true;

        for (auto it = applied.rbegin();
             it != applied.rend();
             ++it)
        {
            // Created by: NeroMorte - Refuse rollback through a
            // reparse-point parent or linked destination object.
            if (HasReparsePointInPath(
                    trustedRoot,
                    it->livePath) ||
                IsReparsePoint(it->livePath))
            {
                rollbackSucceeded = false;

                WriteChatf(
                    "\ar[MQ2WebUpdate]\ax ROLLBACK PARENT REPARSE SAFETY CHECK FAILED: %s",
                    it->livePath.string().c_str()
                );

                continue;
            }

            std::error_code ec;

            if (it->existedBefore)
            {
                std::string backupData;

                if (!ReadFileBinary(
                        it->backupPath,
                        backupData))
                {
                    rollbackSucceeded = false;

                    WriteChatf(
                        "\ar[MQ2WebUpdate]\ax ROLLBACK BACKUP READ FAILED: %s",
                        it->livePath.filename()
                            .string()
                            .c_str()
                    );

                    continue;
                }

                // Created by: NeroMorte - Prove the persisted rollback backup
                // still has the exact transaction identity recorded before
                // any live mutation. Never restore unverified backup bytes.
                const std::string backupSHA256 =
                    ComputeSHA256Hex(backupData);

                if (backupSHA256.empty() ||
                    it->backupSHA256.empty() ||
                    backupSHA256 != it->backupSHA256)
                {
                    rollbackSucceeded = false;

                    WriteChatf(
                        "\ar[MQ2WebUpdate]\ax ROLLBACK BACKUP SHA256 MISMATCH: %s",
                        it->livePath.filename()
                            .string()
                            .c_str()
                    );

                    continue;
                }

                if (!ReplaceRegularFileFromData(
                        it->livePath,
                        backupData))
                {
                    rollbackSucceeded = false;

                    WriteChatf(
                        "\ar[MQ2WebUpdate]\ax ROLLBACK RESTORE FAILED: %s",
                        it->livePath.filename()
                            .string()
                            .c_str()
                    );

                    continue;
                }

                // Created by: NeroMorte - Verify the restored live object
                // independently against the persisted rollback identity.
                std::string restoredData;

                if (!ReadFileBinary(
                        it->livePath,
                        restoredData))
                {
                    rollbackSucceeded = false;

                    WriteChatf(
                        "\ar[MQ2WebUpdate]\ax ROLLBACK RESTORED READ FAILED: %s",
                        it->livePath.filename()
                            .string()
                            .c_str()
                    );

                    continue;
                }

                const std::string restoredSHA256 =
                    ComputeSHA256Hex(restoredData);

                if (restoredSHA256.empty() ||
                    restoredSHA256 != it->backupSHA256)
                {
                    rollbackSucceeded = false;

                    WriteChatf(
                        "\ar[MQ2WebUpdate]\ax ROLLBACK RESTORED SHA256 MISMATCH: %s",
                        it->livePath.filename()
                            .string()
                            .c_str()
                    );

                    continue;
                }

                WriteChatf(
                    "\ay[MQ2WebUpdate]\ax Rolled back + verified: %s",
                    it->livePath.filename()
                        .string()
                        .c_str()
                );

                continue;
            }

            // Created by: NeroMorte - Inspect the destination object
            // before following its target. Never remove a link.
            if (IsReparsePoint(it->livePath))
            {
                rollbackSucceeded = false;

                WriteChatf(
                    "\ar[MQ2WebUpdate]\ax ROLLBACK REFUSED LINK: %s",
                    it->livePath.filename()
                        .string()
                        .c_str()
                );

                continue;
            }

            ec.clear();

            const bool liveExists =
                fs::exists(it->livePath, ec);

            if (ec)
            {
                rollbackSucceeded = false;

                WriteChatf(
                    "\ar[MQ2WebUpdate]\ax ROLLBACK FILE CHECK FAILED: %s",
                    it->livePath.filename()
                        .string()
                        .c_str()
                );

                continue;
            }

            if (!liveExists)
            {
                WriteChatf(
                    "\ay[MQ2WebUpdate]\ax Newly-created file already absent: %s",
                    it->livePath.filename()
                        .string()
                        .c_str()
                );

                continue;
            }

            std::string liveData;

            if (!ReadFileBinary(
                    it->livePath,
                    liveData))
            {
                rollbackSucceeded = false;

                WriteChatf(
                    "\ar[MQ2WebUpdate]\ax ROLLBACK READ FAILED: %s",
                    it->livePath.filename()
                        .string()
                        .c_str()
                );

                continue;
            }

            const std::string liveSHA256 =
                ComputeSHA256Hex(liveData);

            if (liveSHA256.empty() ||
                it->expectedSHA256.empty() ||
                liveSHA256 != it->expectedSHA256)
            {
                rollbackSucceeded = false;

                WriteChatf(
                    "\ar[MQ2WebUpdate]\ax ROLLBACK REFUSED CONTENT MISMATCH: %s",
                    it->livePath.filename()
                        .string()
                        .c_str()
                );

                continue;
            }

            ec.clear();

            const bool removed =
                fs::remove(it->livePath, ec);

            if (ec || !removed)
            {
                rollbackSucceeded = false;

                WriteChatf(
                    "\ar[MQ2WebUpdate]\ax ROLLBACK REMOVE FAILED: %s",
                    it->livePath.filename()
                        .string()
                        .c_str()
                );

                continue;
            }

            // Created by: NeroMorte - Verify no destination object
            // remains after deleting the proven updater-created file.
            if (IsReparsePoint(it->livePath))
            {
                rollbackSucceeded = false;

                WriteChatf(
                    "\ar[MQ2WebUpdate]\ax ROLLBACK POST-REMOVE OBJECT EXISTS: %s",
                    it->livePath.filename()
                        .string()
                        .c_str()
                );

                continue;
            }

            ec.clear();

            const bool stillExists =
                fs::exists(it->livePath, ec);

            if (ec || stillExists)
            {
                rollbackSucceeded = false;

                WriteChatf(
                    "\ar[MQ2WebUpdate]\ax ROLLBACK POST-REMOVE VERIFY FAILED: %s",
                    it->livePath.filename()
                        .string()
                        .c_str()
                );

                continue;
            }

            WriteChatf(
                "\ay[MQ2WebUpdate]\ax Removed updater-created file: %s",
                it->livePath.filename()
                    .string()
                    .c_str()
            );
        }

        return rollbackSucceeded;
    }

    // Produce a verified, isolated DLL handoff. This routine never unloads or
    // replaces the running module. An independent MQ2Lua script does that
    // after this command has returned and the plugin command is off the stack.
    bool PrepareDllHandoff(const std::string& mappingId, std::string& error)
    {
        error.clear();
        if (g_compareRunning.load() || !g_stageReady ||
            HasActiveTransactionRecord())
        {
            error = "A verified, idle staged transaction is required.";
            return false;
        }
        profilemodel::Profile profile;
        if (!SnapshotMainDownloadProfile(profile, error)) return false;
        if (!profilemodel::IsAsciiIdentifier(mappingId))
        {
            error = "A valid plugin mapping ID is required.";
            return false;
        }
        const fs::path luaDir = GetRuntimeLuaDirectory();
        if (luaDir.empty()) { error = "Runtime Lua directory unavailable."; return false; }
        const fs::path root = luaDir.parent_path();
        const fs::path plugins = root / "plugins";
        const fs::path stageRoot = root / "webupdate_stage" / profile.id;
        const fs::path planPath = stageRoot / "stage-plan.ini";
        const fs::path handoffRoot = root / "webupdate_stage";
        const fs::path ticket = handoffRoot / "dll-handoff.ini";
        const fs::path payload = handoffRoot / "dll-handoff-payload.dll";
        if (fs::exists(handoffRoot / "dll-handoff.active"))
        {
            error = "An earlier DLL handoff needs recovery before another can begin.";
            return false;
        }
        if (IsReparsePoint(stageRoot) || IsReparsePoint(handoffRoot) || IsReparsePoint(ticket) ||
            IsReparsePoint(payload))
        {
            error = "An existing DLL handoff path is a protected link.";
            return false;
        }
        std::error_code cleanupError;
        fs::remove(ticket, cleanupError);
        if (cleanupError) { error = "Could not clear the old DLL handoff ticket."; return false; }
        fs::remove(payload, cleanupError);
        if (cleanupError) { error = "Could not clear the old DLL handoff payload."; return false; }
        std::string raw;
        mq2webupdate::stageplan::Manifest plan;
        if (IsReparsePoint(stageRoot) || IsReparsePoint(planPath) ||
            !ReadFileBinary(planPath, raw) ||
            !mq2webupdate::stageplan::Parse(raw, plan, error) ||
            !mq2webupdate::stageplan::MatchesProfile(plan, profile))
        {
            if (error.empty()) error = "Staged plan is absent or differs from the current repository profile.";
            return false;
        }
        const mq2webupdate::planner::PlanItem* dll = nullptr;
        for (const auto& item : plan.items)
        {
            if (item.mappingId == mappingId)
            {
                if (dll || item.destinationRoot != profilemodel::DestinationRoot::Plugins)
                {
                    error = "Plugin mapping must stage exactly one DLL.";
                    return false;
                }
                dll = &item;
            }
        }
        if (!dll) { error = "No staged DLL exists for this mapping."; return false; }
        const auto selected = std::find_if(profile.mappings.begin(), profile.mappings.end(),
            [&](const profilemodel::Mapping& mapping) { return mapping.id == mappingId; });
        if (selected == profile.mappings.end() || !selected->enabled ||
            selected->destinationRoot != profilemodel::DestinationRoot::Plugins)
        {
            error = "The staged DLL mapping is no longer enabled for plugins.";
            return false;
        }
        const std::string remoteRoot =
            mq2webupdate::planner::NormalizeRepositoryPath(selected->remotePath);
        const std::string remotePath =
            mq2webupdate::planner::NormalizeRepositoryPath(dll->repositoryPath);
        std::string relative;
        if (remotePath == remoteRoot)
        {
            relative = remotePath.substr(remotePath.find_last_of('/') == std::string::npos
                ? 0 : remotePath.find_last_of('/') + 1);
        }
        else if (remotePath.rfind(remoteRoot + "/", 0) == 0)
            relative = remotePath.substr(remoteRoot.size() + 1);
        const fs::path configuredDestination =
            fs::path(selected->destinationPath) / fs::path(relative);
        if (relative.empty() ||
            dll->stageRelativePath != mappingId + "/" + relative ||
            configuredDestination.generic_string() != dll->destinationRelativePath)
        {
            error = "Staged DLL no longer matches its saved deployment mapping.";
            return false;
        }
        const std::string destinationName = dll->destinationRelativePath;
        const fs::path destinationFile(destinationName);
        const std::string pluginName = destinationFile.stem().string();
        if (destinationFile.filename().string() != destinationName ||
            destinationFile.extension().string() != ".dll" ||
            !profilemodel::IsAsciiIdentifier(pluginName) ||
            destinationName != pluginName + ".dll")
        {
            error = "Plugin mapping must target a single safe DLL filename.";
            return false;
        }
        const fs::path live = plugins / destinationName;
        const fs::path staged = stageRoot / plan.commitSha / dll->stageRelativePath;
        if (HasReparsePointInPath(stageRoot, staged) ||
            IsReparsePoint(handoffRoot) ||
            HasReparsePointInPath(plugins, live) ||
            IsReparsePoint(staged) || IsReparsePoint(live) ||
            IsReparsePoint(ticket) || IsReparsePoint(payload))
        {
            error = "A plugin or staging path is a protected link.";
            return false;
        }
        std::error_code existsError;
        const bool oldPresent = fs::exists(live, existsError);
        const bool oldRegular = oldPresent && fs::is_regular_file(live, existsError);
        if (existsError || (oldPresent && !oldRegular))
        {
            error = "Installed plugin path is unavailable or is not a regular file.";
            return false;
        }
        std::string bytes, old;
        if (!ReadFileBinary(staged, bytes) ||
            (oldPresent && !ReadFileBinary(live, old)) ||
            bytes.size() != dll->expectedSize ||
            ComputeGitBlobSha(bytes) != dll->gitObjectSha ||
            (oldPresent && bytes == old))
        {
            error = "Staged DLL is missing, changed, or identical to the installed DLL.";
            return false;
        }
        auto pe32 = [](const std::string& b)
        {
            if (b.size() < 512 || b[0] != 'M' || b[1] != 'Z') return false;
            const auto u8 = [&](std::size_t i) { return static_cast<unsigned char>(b[i]); };
            const std::size_t off = std::size_t(u8(60)) |
                (std::size_t(u8(61)) << 8) | (std::size_t(u8(62)) << 16) |
                (std::size_t(u8(63)) << 24);
            return off <= b.size() - 26 && b.compare(off, 4, "PE\0\0", 4) == 0 &&
                u8(off + 4) == 0x4c && u8(off + 5) == 0x01 &&
                (u8(off + 23) & 0x20) != 0 &&
                u8(off + 24) == 0x0b && u8(off + 25) == 0x01;
        };
        if ((oldPresent && !pe32(old)) || !pe32(bytes))
        {
            error = "DLL is not a compatible PE32 x86 binary.";
            return false;
        }
        if (!WriteFileBinaryAtomic(payload, bytes))
        {
            error = "Could not create the verified DLL handoff payload.";
            return false;
        }
        std::ostringstream out;
        out << "Format=MQ2WebUpdateDllHandoff\n"
            << "Version=1\n"
            << "ProfileID=" << profile.id << "\n"
            << "MappingID=" << mappingId << "\n"
            << "PluginName=" << pluginName << "\n"
            << "DestinationName=" << destinationName << "\n"
            << "CommitSHA=" << plan.commitSha << "\n"
            << "OldPresent=" << (oldPresent ? "1" : "0") << "\n"
            << "ExpectedSize=" << bytes.size() << "\n"
            << "ExpectedSHA256=" << ComputeSHA256Hex(bytes) << "\n"
            << "OriginalSHA256=" << (oldPresent ? ComputeSHA256Hex(old) : std::string(64, '0')) << "\n";
        if (!WriteFileBinaryAtomic(ticket, out.str()))
        {
            error = "Could not publish the DLL handoff ticket.";
            return false;
        }
        return true;
    }

    bool ApplyStagedLuaFiles()
    {
        g_status = "Applying";
        g_lastError.clear();

        profilemodel::Profile profile;
        if (!SnapshotMainDownloadProfile(profile, g_lastError))
        {
            g_status = "Apply Error";
            WriteChatf("\ar[MQ2WebUpdate]\ax %s", g_lastError.c_str());
            return false;
        }

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
            profile.id;

        const fs::path planPath = stageRoot / "stage-plan.ini";

        if (!fs::exists(stageRoot))
        {
            WriteChatf(
                "\ay[MQ2WebUpdate]\ax No staging folder exists."
            );

            g_status = "Nothing Staged";
            return true;
        }

        std::string planData;
        mq2webupdate::stageplan::Manifest stageManifest;
        std::string planError;

        if (!ReadFileBinary(planPath, planData) ||
            !mq2webupdate::stageplan::Parse(
                planData, stageManifest, planError))
        {
            g_status = "Apply Error";
            g_lastError =
                "The committed stage plan is missing or invalid.";

            WriteChatf(
                "\ar[MQ2WebUpdate]\ax %s",
                g_lastError.c_str()
            );

            return false;
        }

        if (!mq2webupdate::stageplan::MatchesProfile(
                stageManifest, profile))
        {
            g_status = "Apply Error";
            g_lastError =
                "The staged repository identity no longer matches the Main Download profile.";

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
        g_remoteSha = stageManifest.commitSha;

        fs::path stageDirectory =
            stageRoot /
            stageManifest.commitSha;

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
            (stageManifest.owner + "/" + stageManifest.repository).c_str()
        );

        WriteChatf(
            "\ay[MQ2WebUpdate]\ax Stage branch: %s",
            stageManifest.reference.c_str()
        );

        WriteChatf(
            "\ay[MQ2WebUpdate]\ax Stage SHA: %s",
            stageManifest.commitSha.c_str()
        );

        std::vector<fs::path> stagedFiles;
        std::map<std::string, const mq2webupdate::planner::PlanItem*> stagedItems;

        for (const auto& item : stageManifest.items)
        {
            stagedItems.emplace(item.stageRelativePath, &item);
            stagedFiles.push_back(stageDirectory / item.stageRelativePath);
        }

        std::error_code ec;
        std::set<std::string> physicalStagePaths;

        for (const auto& entry :
             fs::recursive_directory_iterator(
                 stageDirectory,
                 ec))
        {
            if (ec)
                break;

            if (IsReparsePoint(entry.path()) ||
                HasReparsePointInPath(stageDirectory, entry.path()))
            {
                ec = std::make_error_code(std::errc::operation_not_permitted);
                break;
            }

            if (!entry.is_regular_file()) continue;

            const fs::path relative =
                fs::relative(entry.path(), stageDirectory, ec);
            if (ec || relative.empty() || relative.is_absolute()) break;
            physicalStagePaths.insert(relative.generic_string());
        }

        if (ec)
        {
            g_status = "Apply Error";
            g_lastError =
                "Could not safely enumerate the staging directory.";

            WriteChatf(
                "\ar[MQ2WebUpdate]\ax %s",
                g_lastError.c_str()
            );

            return false;
        }

        std::set<std::string> expectedStagePaths;
        for (const auto& item : stageManifest.items)
            expectedStagePaths.insert(item.stageRelativePath);

        if (physicalStagePaths != expectedStagePaths)
        {
            g_status = "Apply Error";
            g_lastError =
                "Staged files do not exactly match the committed deployment plan.";
            WriteChatf("\ar[MQ2WebUpdate]\ax %s", g_lastError.c_str());
            return false;
        }

        if (stagedFiles.empty())
        {
            WriteChatf(
                "\ay[MQ2WebUpdate]\ax No changed or missing files were staged."
            );

            g_status = "Nothing Staged";
            return true;
        }

        // Created by: NeroMorte - WHOLE-TRANSACTION PREFLIGHT.
        // Validate every staged source and live destination before
        // creating a transaction or permitting any live mutation.
        // One unsafe destination rejects the entire Apply.
        std::vector<ApplyPlanEntry> preflightPlan;
        preflightPlan.reserve(stagedFiles.size());

        size_t preflightProtectedCount = 0;
        size_t preflightErrorCount = 0;

        for (const auto& stagePath : stagedFiles)
        {
            ec.clear();

            fs::path relativePath =
                fs::relative(
                    stagePath,
                    stageDirectory,
                    ec
                );

            if (ec ||
                relativePath.empty() ||
                relativePath.is_absolute())
            {
                ++preflightErrorCount;

                WriteChatf(
                    "\ar[MQ2WebUpdate]\ax PREFLIGHT: invalid staged relative path."
                );

                break;
            }

            bool unsafeRelativePath = false;

            for (const auto& part : relativePath)
            {
                if (part == "..")
                {
                    unsafeRelativePath = true;
                    break;
                }
            }

            if (unsafeRelativePath)
            {
                ++preflightErrorCount;

                WriteChatf(
                    "\ar[MQ2WebUpdate]\ax PREFLIGHT: path traversal rejected: %s",
                    relativePath.string().c_str()
                );

                break;
            }

            const auto itemFound =
                stagedItems.find(relativePath.generic_string());
            if (itemFound == stagedItems.end())
            {
                ++preflightErrorCount;
                WriteChatf(
                    "\ar[MQ2WebUpdate]\ax PREFLIGHT: staged file is not present in the committed plan."
                );
                break;
            }

            const auto& stagedItem = *itemFound->second;
            const fs::path trustedDestinationRoot =
                profilemodel::ResolveDestinationRoot(
                    runtimeRoot, stagedItem.destinationRoot);
            fs::path livePath =
                trustedDestinationRoot /
                stagedItem.destinationRelativePath;

            // Created by: NeroMorte - Reject a destination whose
            // trusted root or existing parent path is a reparse point.
            if (HasReparsePointInPath(
                    trustedDestinationRoot,
                    livePath))
            {
                ++preflightProtectedCount;

                WriteChatf(
                    "\ar[MQ2WebUpdate]\ax PREFLIGHT: parent reparse path rejected: %s",
                    stagedItem.destinationRelativePath.c_str()
                );

                break;
            }

            std::string relativeName =
                fs::path(stagedItem.destinationRelativePath).filename().string();

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

            // The plugin cannot replace its own loaded DLL. Keep the entire
            // staged transaction intact for the independent handoff.
            if (stagedItem.destinationRoot ==
                    profilemodel::DestinationRoot::Plugins &&
                relativeName.size() >= 4 &&
                relativeName.compare(relativeName.size() - 4, 4, ".dll") == 0)
            {
                ++preflightProtectedCount;
                WriteChatf("\ar[MQ2WebUpdate]\ax A plugin DLL requires an independent unload handoff; ordinary Apply stopped.");
                break;
            }

            // The running updater/controller cannot be replaced
            // safely inside its own transaction.
            ec.clear();

            const bool controllerExists =
                relativeName == "updater.lua" &&
                fs::exists(livePath, ec);

            if (ec)
            {
                ++preflightErrorCount;

                WriteChatf(
                    "\ar[MQ2WebUpdate]\ax PREFLIGHT: destination check failed: %s",
                    relativePath.string().c_str()
                );

                break;
            }

            if (controllerExists)
            {
                ++preflightProtectedCount;

                WriteChatf(
                    "\ao[MQ2WebUpdate]\ax PREFLIGHT: controller destination rejected: %s",
                    relativePath.string().c_str()
                );

                continue;
            }

            // Inspect the destination object itself before following
            // a target. This includes dangling symbolic links.
            if (IsReparsePoint(livePath))
            {
                ++preflightProtectedCount;

                WriteChatf(
                    "\ao[MQ2WebUpdate]\ax PREFLIGHT: protected link rejected: %s",
                    relativePath.string().c_str()
                );

                continue;
            }

            ec.clear();

            const bool existedBefore =
                fs::exists(livePath, ec);

            if (ec)
            {
                ++preflightErrorCount;

                WriteChatf(
                    "\ar[MQ2WebUpdate]\ax PREFLIGHT: live file check failed: %s",
                    relativePath.string().c_str()
                );

                break;
            }

            std::string stagedData;

            if (!ReadFileBinary(
                    stagePath,
                    stagedData))
            {
                ++preflightErrorCount;

                WriteChatf(
                    "\ar[MQ2WebUpdate]\ax PREFLIGHT: staged file unreadable: %s",
                    relativePath.string().c_str()
                );

                break;
            }

            if (stagedData.size() != stagedItem.expectedSize)
            {
                ++preflightErrorCount;
                WriteChatf(
                    "\ar[MQ2WebUpdate]\ax PREFLIGHT: staged size mismatch: %s",
                    stagedItem.destinationRelativePath.c_str()
                );
                break;
            }

            const std::string stagedSHA256 =
                ComputeSHA256Hex(stagedData);

            if (stagedSHA256.empty())
            {
                ++preflightErrorCount;

                WriteChatf(
                    "\ar[MQ2WebUpdate]\ax PREFLIGHT: staged SHA256 failed: %s",
                    relativePath.string().c_str()
                );

                break;
            }

            std::string originalSHA256;

            if (existedBefore)
            {
                std::string currentData;

                if (!ReadFileBinary(
                        livePath,
                        currentData))
                {
                    ++preflightErrorCount;

                    WriteChatf(
                        "\ar[MQ2WebUpdate]\ax PREFLIGHT: live file unreadable: %s",
                        relativePath.string().c_str()
                    );

                    break;
                }

                originalSHA256 =
                    ComputeSHA256Hex(currentData);

                if (originalSHA256.empty())
                {
                    ++preflightErrorCount;

                    WriteChatf(
                        "\ar[MQ2WebUpdate]\ax PREFLIGHT: live SHA256 failed: %s",
                        relativePath.string().c_str()
                    );

                    break;
                }
            }

            ApplyPlanEntry planEntry;
            planEntry.stagePath = stagePath;
            planEntry.relativePath =
                fs::path(profilemodel::DestinationRootName(
                    stagedItem.destinationRoot)) /
                stagedItem.destinationRelativePath;
            planEntry.trustedDestinationRoot = trustedDestinationRoot;
            planEntry.livePath = livePath;
            planEntry.existedBefore = existedBefore;
            planEntry.stagedSHA256 = stagedSHA256;
            planEntry.originalSHA256 = originalSHA256;

            preflightPlan.push_back(
                std::move(planEntry)
            );
        }

        // Created by: NeroMorte - A successful preflight must
        // describe every staged file exactly once.
        if (preflightProtectedCount == 0 &&
            preflightErrorCount == 0 &&
            preflightPlan.size() != stagedFiles.size())
        {
            ++preflightErrorCount;

            WriteChatf(
                "\ar[MQ2WebUpdate]\ax PREFLIGHT: plan snapshot count mismatch."
            );
        }

        if (preflightProtectedCount > 0 ||
            preflightErrorCount > 0)
        {
            g_status = "Apply Preflight Failed";

            if (preflightProtectedCount > 0)
            {
                g_lastError =
                    "Preflight rejected the transaction because one or more destinations are protected.";
            }
            else
            {
                g_lastError =
                    "Preflight rejected the transaction because one or more files could not be safely validated.";
            }

            WriteChatf(
                "\ar[MQ2WebUpdate]\ax %s",
                g_lastError.c_str()
            );

            WriteChatf(
                "\ar[MQ2WebUpdate]\ax Preflight rejected: protected=%zu errors=%zu",
                preflightProtectedCount,
                preflightErrorCount
            );

            WriteChatf(
                "\ag[MQ2WebUpdate]\ax No live file was modified."
            );

            return false;
        }

        WriteChatf(
            "\ag[MQ2WebUpdate]\ax Preflight passed with %zu validated plan entrie(s).",
            preflightPlan.size()
        );

        const std::string backupTimestamp =
            MakeTimestamp();

        fs::path backupDirectory =
            runtimeRoot /
            "webupdate_backup" /
            profile.id /
            stageManifest.commitSha /
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
            "\ay[MQ2WebUpdate]\ax Applying validated multi-root update..."
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
        /*
            Created by: NeroMorte - TRANSACTION-WIDE BACKUP PHASE V1.

            Revalidate every immutable preflight identity and create +
            byte-verify every required backup before PREPARED/APPLYING
            can become durable and before any live replacement begins.
        */
        std::vector<AppliedFileChange> preparedChanges;
        preparedChanges.reserve(preflightPlan.size());

        size_t backupPreparationErrors = 0;

        for (const auto& planEntry : preflightPlan)
        {
            // Created by: NeroMorte - Revalidate the live parent path
            // before rollback data is prepared for this transaction.
            if (HasReparsePointInPath(
                    planEntry.trustedDestinationRoot,
                    planEntry.livePath))
            {
                ++backupPreparationErrors;

                WriteChatf(
                    "\ar[MQ2WebUpdate]\ax %s: BACKUP PREPARATION PARENT REPARSE PATH",
                    planEntry.relativePath.string().c_str()
                );

                break;
            }

            const fs::path& stagePath =
                planEntry.stagePath;

            const fs::path& relativePath =
                planEntry.relativePath;

            const fs::path& livePath =
                planEntry.livePath;

            fs::path backupPath =
                backupDirectory / relativePath;

            std::string backupSHA256;

            if (IsReparsePoint(livePath))
            {
                ++backupPreparationErrors;
                WriteChatf(
                    "\ar[MQ2WebUpdate]\ax %s: BACKUP PREFLIGHT - REPARSE POINT",
                    relativePath.string().c_str()
                );
                break;
            }

            ec.clear();

            const bool existedBefore =
                fs::exists(livePath, ec);

            if (ec)
            {
                ++backupPreparationErrors;
                WriteChatf(
                    "\ar[MQ2WebUpdate]\ax %s: BACKUP PREFLIGHT - LIVE CHECK ERROR",
                    relativePath.string().c_str()
                );
                break;
            }

            if (existedBefore != planEntry.existedBefore)
            {
                ++backupPreparationErrors;
                WriteChatf(
                    "\ar[MQ2WebUpdate]\ax %s: BACKUP PREFLIGHT - EXISTENCE CHANGED",
                    relativePath.string().c_str()
                );
                break;
            }

            std::string stagedData;

            if (!ReadFileBinary(
                    stagePath,
                    stagedData))
            {
                ++backupPreparationErrors;
                WriteChatf(
                    "\ar[MQ2WebUpdate]\ax %s: BACKUP PREFLIGHT - STAGED READ ERROR",
                    relativePath.string().c_str()
                );
                break;
            }

            const std::string stagedSHA256 =
                ComputeSHA256Hex(stagedData);

            if (stagedSHA256.empty() ||
                stagedSHA256 != planEntry.stagedSHA256)
            {
                ++backupPreparationErrors;
                WriteChatf(
                    "\ar[MQ2WebUpdate]\ax %s: BACKUP PREFLIGHT - STAGED SHA256 CHANGED",
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
                    ++backupPreparationErrors;
                    WriteChatf(
                        "\ar[MQ2WebUpdate]\ax %s: BACKUP PREFLIGHT - LIVE READ ERROR",
                        relativePath.string().c_str()
                    );
                    break;
                }

                const std::string originalSHA256 =
                    ComputeSHA256Hex(currentData);

                if (originalSHA256.empty() ||
                    originalSHA256 != planEntry.originalSHA256)
                {
                    ++backupPreparationErrors;
                    WriteChatf(
                        "\ar[MQ2WebUpdate]\ax %s: BACKUP PREFLIGHT - LIVE SHA256 CHANGED",
                        relativePath.string().c_str()
                    );
                    break;
                }

                ec.clear();

                fs::create_directories(
                    backupPath.parent_path(),
                    ec
                );

                if (ec ||
                    !WriteFileBinary(
                        backupPath,
                        currentData))
                {
                    ++backupPreparationErrors;
                    WriteChatf(
                        "\ar[MQ2WebUpdate]\ax %s: TRANSACTION BACKUP WRITE ERROR",
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
                    ++backupPreparationErrors;
                    WriteChatf(
                        "\ar[MQ2WebUpdate]\ax %s: TRANSACTION BACKUP VERIFY ERROR",
                        relativePath.string().c_str()
                    );
                    break;
                }

                backupSHA256 =
                    ComputeSHA256Hex(verifyBackup);

                if (backupSHA256.empty() ||
                    backupSHA256 != planEntry.originalSHA256)
                {
                    ++backupPreparationErrors;
                    WriteChatf(
                        "\ar[MQ2WebUpdate]\ax %s: TRANSACTION BACKUP SHA256 ERROR",
                        relativePath.string().c_str()
                    );
                    break;
                }
            }

            AppliedFileChange preparedChange;
            preparedChange.livePath = livePath;

            // Created by: NeroMorte - New files have no rollback backup object.
            // Persist an empty BackupPath for them so the manifest exactly
            // represents rollback semantics and recovery can fail closed.
            preparedChange.backupPath =
                existedBefore
                    ? backupPath
                    : fs::path();

            preparedChange.existedBefore = existedBefore;
            preparedChange.backupSHA256 = backupSHA256;
            preparedChange.expectedSHA256 =
                planEntry.stagedSHA256;
            preparedChange.transactionState =
                "PENDING";

            preparedChanges.push_back(
                std::move(preparedChange)
            );
        }

        if (backupPreparationErrors > 0 ||
            preparedChanges.size() != preflightPlan.size())
        {
            g_status =
                "Apply Backup Preparation Failed";

            g_lastError =
                "Transaction-wide identity revalidation or backup preparation failed before live mutation.";

            WriteChatf(
                "\ar[MQ2WebUpdate]\ax %s",
                g_lastError.c_str()
            );

            WriteChatf(
                "\ar[MQ2WebUpdate]\ax Prepared %zu of %zu rollback identities. No live file was modified.",
                preparedChanges.size(),
                preflightPlan.size()
            );

            return false;
        }

        WriteChatf(
            "\ag[MQ2WebUpdate]\ax Transaction-wide backup preparation passed for %zu file(s).",
            preparedChanges.size()
        );


        // Created by: NeroMorte - Persist Apply transaction identity
        // before any live-file mutation can begin.
        fs::path applyManifestPath =
            backupDirectory /
            "apply_transaction.ini";

        ApplyTransactionManifest applyManifest;

        // Created by: NeroMorte - PREPARED now contains the complete
        // transaction-wide rollback identity produced before mutation.
        applyManifest.changes =
            preparedChanges;

        applyManifest.state =
            "PREPARED";

        applyManifest.profileId =
            profile.id;

        applyManifest.provider =
            profilemodel::SourceProviderName(profile.provider);

        applyManifest.repository =
            stageManifest.owner + "/" + stageManifest.repository;

        applyManifest.branch =
            stageManifest.reference;

        applyManifest.remoteSha =
            stageManifest.commitSha;

        applyManifest.stageDirectory =
            stageDirectory;

        applyManifest.backupDirectory =
            backupDirectory;

        if (!WriteApplyTransactionManifest(
                applyManifestPath,
                applyManifest))
        {
            g_status = "Apply Error";
            g_lastError =
                "Apply transaction manifest could not be prepared.";

            WriteChatf(
                "\ar[MQ2WebUpdate]\ax %s",
                g_lastError.c_str()
            );

            return false;
        }

        // Created by: NeroMorte - Publish the single active transaction pointer only after PREPARED
        // is durable and before APPLYING or any live-file mutation can begin.
        if (!WriteActiveApplyTransactionRecord(
                runtimeRoot,
                applyManifestPath))
        {
            g_status = "Apply Error";
            g_lastError =
                "Apply transaction active record could not be published. No live files were changed.";

            WriteChatf(
                "\ar[MQ2WebUpdate]\ax %s",
                g_lastError.c_str()
            );

            WriteChatf(
                "\ar[MQ2WebUpdate]\ax Stage and backups were NOT deleted."
            );

            return false;
        }

        std::vector<AppliedFileChange> applied;

        // Created by: NeroMorte - PREPARED identity and its active pointer
        // are durable. Mark APPLYING before any live-file mutation.
        applyManifest.state =
            "APPLYING";

        if (!WriteApplyTransactionManifest(
                applyManifestPath,
                applyManifest))
        {
            // Created by: NeroMorte - APPLYING was not durable, so no live mutation is permitted.
            // The previously durable manifest remains PREPARED. Remove the active pointer
            // because this Apply attempt never crossed the live-mutation boundary.
            if (!ClearActiveApplyTransactionRecord(runtimeRoot))
            {
                g_status = "Apply Error - Recovery Record";
                g_lastError =
                    "Apply could not enter APPLYING state, and the active transaction record could not be cleared. No live files were changed.";

                WriteChatf(
                    "\ar[MQ2WebUpdate]\ax %s",
                    g_lastError.c_str()
                );

                WriteChatf(
                    "\ar[MQ2WebUpdate]\ax Stage and backups were NOT deleted."
                );

                return false;
            }

            g_status = "Apply Error";
            g_lastError =
                "Apply transaction could not enter APPLYING state. No live files were changed.";

            WriteChatf(
                "\ar[MQ2WebUpdate]\ax %s",
                g_lastError.c_str()
            );

            WriteChatf(
                "\ar[MQ2WebUpdate]\ax Active transaction record was cleared; PREPARED manifest and backups were kept."
            );

            return false;
        }

        // Created by: NeroMorte - Consume the transaction-wide prepared
        // rollback identities by stable index. No live rediscovery or
        // duplicate backup occurs after APPLYING begins.
        for (size_t planIndex = 0;
             planIndex < preflightPlan.size();
             ++planIndex)
        {
            const auto& planEntry =
                preflightPlan[planIndex];

            const fs::path& stagePath =
                planEntry.stagePath;

            const fs::path& relativePath =
                planEntry.relativePath;

            const fs::path& livePath =
                planEntry.livePath;

            AppliedFileChange& manifestChange =
                applyManifest.changes[planIndex];

            /*
                Created by: NeroMorte - Fail closed if the prepared
                rollback identity and immutable plan are no longer aligned.
            */
            if (manifestChange.livePath != livePath ||
                manifestChange.existedBefore != planEntry.existedBefore ||
                manifestChange.expectedSHA256 != planEntry.stagedSHA256)
            {
                ++errorCount;

                WriteChatf(
                    "\ar[MQ2WebUpdate]\ax %s: PREPARED TRANSACTION IDENTITY MISMATCH",
                    relativePath.string().c_str()
                );

                break;
            }

            if (manifestChange.existedBefore)
            {
                if (manifestChange.backupSHA256.empty())
                {
                    ++errorCount;

                    WriteChatf(
                        "\ar[MQ2WebUpdate]\ax %s: PREPARED BACKUP SHA256 MISSING",
                        relativePath.string().c_str()
                    );

                    break;
                }
            }
            else if (!manifestChange.backupSHA256.empty())
            {
                ++errorCount;

                WriteChatf(
                    "\ar[MQ2WebUpdate]\ax %s: UNEXPECTED BACKUP SHA256 FOR NEW FILE",
                    relativePath.string().c_str()
                );

                break;
            }

            /*
                Created by: NeroMorte - Final staged-content identity
                verification immediately before live replacement.
            */
            std::string stagedData;

            if (!ReadFileBinary(
                    stagePath,
                    stagedData))
            {
                ++errorCount;

                WriteChatf(
                    "\ar[MQ2WebUpdate]\ax %s: FINAL STAGED READ ERROR",
                    relativePath.string().c_str()
                );

                break;
            }

            const std::string currentStagedSHA256 =
                ComputeSHA256Hex(stagedData);

            if (currentStagedSHA256.empty() ||
                currentStagedSHA256 !=
                    manifestChange.expectedSHA256)
            {
                ++errorCount;

                WriteChatf(
                    "\ar[MQ2WebUpdate]\ax %s: FINAL STAGED SHA256 CHANGED",
                    relativePath.string().c_str()
                );

                break;
            }

            /*
                Created by: NeroMorte - Persist PENDING for this exact
                pre-created manifest slot immediately before replacement.
            */
            // Created by: NeroMorte - Close the parent-path TOCTOU
            // window immediately before PENDING and live replacement.
            if (HasReparsePointInPath(
                    planEntry.trustedDestinationRoot,
                    livePath) ||
                IsReparsePoint(livePath))
            {
                ++errorCount;

                WriteChatf(
                    "\ar[MQ2WebUpdate]\ax %s: FINAL DESTINATION REPARSE SAFETY CHECK FAILED",
                    relativePath.string().c_str()
                );

                break;
            }

            manifestChange.transactionState =
                "PENDING";

            if (!WriteApplyTransactionManifest(
                    applyManifestPath,
                    applyManifest))
            {
                ++errorCount;

                WriteChatf(
                    "\ar[MQ2WebUpdate]\ax %s: TRANSACTION MANIFEST WRITE ERROR",
                    relativePath.string().c_str()
                );

                break;
            }

            /*
                Created by: NeroMorte - Once tracked here, replacement may
                begin and rollback must consider this file.
            */
            applied.push_back(
                manifestChange
            );

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

            // Created by: NeroMorte - Replacement and live verification
            // succeeded; persist that fact in the matching manifest slot.
            manifestChange.transactionState =
                "APPLIED_VERIFIED";

            if (!WriteApplyTransactionManifest(
                    applyManifestPath,
                    applyManifest))
            {
                ++errorCount;

                WriteChatf(
                    "\ar[MQ2WebUpdate]\ax %s: POST-APPLY MANIFEST WRITE ERROR",
                    relativePath.string().c_str()
                );

                break;
            }

            ++appliedCount;

            if (manifestChange.existedBefore)
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
            const bool rollbackSucceeded =
                RollbackAppliedFiles(applied, runtimeRoot);

            // Created by: NeroMorte - Persist whether rollback completed
            // safely. Never claim ROLLED_BACK when any file was ambiguous.
            applyManifest.state =
                rollbackSucceeded
                    ? "ROLLED_BACK"
                    : "ROLLBACK_FAILED";

            if (!WriteApplyTransactionManifest(
                    applyManifestPath,
                    applyManifest))
            {
                g_status = "Apply Failed - Manifest Error";

                if (rollbackSucceeded)
                {
                    g_lastError =
                        "Apply failed and rollback completed, but ROLLED_BACK state could not be persisted.";
                }
                else
                {
                    g_lastError =
                        "Apply failed, rollback was incomplete, and ROLLBACK_FAILED state could not be persisted.";
                }

                WriteChatf(
                    "\ar[MQ2WebUpdate]\ax %s",
                    g_lastError.c_str()
                );

                WriteChatf(
                    "\ar[MQ2WebUpdate]\ax Stage and backups were NOT deleted."
                );

                return false;
            }

            if (rollbackSucceeded)
            {
                // Created by: NeroMorte - Clear the active pointer only after ROLLED_BACK
                // was durably persisted. Failure to clear keeps recovery evidence intact.
                if (!ClearActiveApplyTransactionRecord(runtimeRoot))
                {
                    g_status = "Apply Failed - Recovery Record Error";
                    g_lastError =
                        "Apply failed and rollback completed, but the active transaction record could not be cleared.";

                    WriteChatf(
                        "\ar[MQ2WebUpdate]\ax %s",
                        g_lastError.c_str()
                    );

                    WriteChatf(
                        "\ar[MQ2WebUpdate]\ax Stage and backups were NOT deleted."
                    );

                    return false;
                }

                g_status = "Apply Failed - Rolled Back";
                g_lastError =
                    "Apply failed. Rollback completed and was verified.";
            }
            else
            {
                g_status = "Apply Failed - Rollback Failed";
                g_lastError =
                    "Apply failed. Rollback was incomplete or ambiguous.";
            }

            WriteChatf(
                "\ar[MQ2WebUpdate]\ax %s",
                g_lastError.c_str()
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

        // Created by: NeroMorte - All tracked live replacements were
        // applied and verified with no protected destinations skipped.
        // Commit before best-effort legacy and staging cleanup.
        applyManifest.state =
            "COMMITTED";

        if (!WriteApplyTransactionManifest(
                applyManifestPath,
                applyManifest))
        {
            g_status = "Apply Error - Commit Manifest";
            g_lastError =
                "Live replacements were verified, but COMMITTED state could not be persisted. Stage and backups were kept.";

            WriteChatf(
                "\ar[MQ2WebUpdate]\ax %s",
                g_lastError.c_str()
            );

            WriteChatf(
                "\ar[MQ2WebUpdate]\ax Stage and backups were NOT deleted."
            );

            return false;
        }

        // Created by: NeroMorte - COMMITTED is durable; clear the active transaction pointer
        // before best-effort legacy and staging cleanup. Never roll back a committed update.
        if (!ClearActiveApplyTransactionRecord(runtimeRoot))
        {
            g_status = "Apply Error - Recovery Record";
            g_lastError =
                "Update was committed, but the active transaction record could not be cleared. Stage and backups were kept.";

            WriteChatf(
                "\ar[MQ2WebUpdate]\ax %s",
                g_lastError.c_str()
            );

            WriteChatf(
                "\ar[MQ2WebUpdate]\ax Live files remain COMMITTED; rollback was NOT attempted."
            );

            return false;
        }

        // Created by: NeroMorte - remove obsolete legacy flat-layout files
        // only after the replacement layout was fully applied and verified.
        //
        // Each legacy file is copied into this transaction's backup folder
        // before removal. Reparse points are never deleted.
        // v4 never infers deletions from a repository update. Legacy cleanup
        // must be an explicit, separately reviewed maintenance action.
        const std::vector<std::string> legacyFlatFiles;

        bool legacyCleanupWarning = false;

        for (const auto& legacyName : legacyFlatFiles)
        {
            fs::path legacyPath =
                luaDirectory / legacyName;

            ec.clear();

            const bool legacyExists =
                fs::exists(legacyPath, ec);

            if (ec)
            {
                legacyCleanupWarning = true;

                WriteChatf(
                    "\ay[MQ2WebUpdate]\ax Legacy cleanup check failed: %s",
                    legacyName.c_str()
                );

                continue;
            }

            if (!legacyExists)
                continue;

            if (IsReparsePoint(legacyPath))
            {
                legacyCleanupWarning = true;

                WriteChatf(
                    "\ao[MQ2WebUpdate]\ax Legacy link preserved: %s",
                    legacyName.c_str()
                );

                continue;
            }

            std::string legacyData;

            if (!ReadFileBinary(
                    legacyPath,
                    legacyData))
            {
                legacyCleanupWarning = true;

                WriteChatf(
                    "\ay[MQ2WebUpdate]\ax Could not read legacy file for backup: %s",
                    legacyName.c_str()
                );

                continue;
            }

            fs::path legacyBackupPath =
                backupDirectory /
                "legacy_flat_layout" /
                legacyName;

            if (!WriteFileBinary(
                    legacyBackupPath,
                    legacyData))
            {
                legacyCleanupWarning = true;

                WriteChatf(
                    "\ay[MQ2WebUpdate]\ax Could not back up legacy file: %s",
                    legacyName.c_str()
                );

                continue;
            }

            ec.clear();

            fs::remove(
                legacyPath,
                ec
            );

            if (ec ||
                fs::exists(legacyPath))
            {
                legacyCleanupWarning = true;

                WriteChatf(
                    "\ay[MQ2WebUpdate]\ax Legacy file could not be removed: %s",
                    legacyName.c_str()
                );

                continue;
            }

            WriteChatf(
                "\ag[MQ2WebUpdate]\ax Legacy flat-layout file removed: %s",
                legacyName.c_str()
            );
        }

        ec.clear();

        fs::remove_all(
            stageRoot,
            ec
        );

        if (ec || legacyCleanupWarning)
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
class MQ2WebUpdateTreeFileType;
class MQ2WebUpdateProfileType;
class MQ2WebUpdateManagedProfileType;
class MQ2WebUpdateMappingType;
class MQ2WebUpdateType;

MQ2WebUpdateFileType* pWebUpdateFileType = nullptr;
MQ2WebUpdateTreeFileType* pWebUpdateTreeFileType = nullptr;
MQ2WebUpdateProfileType* pWebUpdateProfileType = nullptr;
MQ2WebUpdateManagedProfileType* pWebUpdateManagedProfileType = nullptr;
MQ2WebUpdateMappingType* pWebUpdateMappingType = nullptr;
MQ2WebUpdateType* pWebUpdateType = nullptr;


class MQ2WebUpdateFileType : public MQ2Type
{
public:
    enum Members
    {
        Name = 1,
        RepoPath,
        Status,
        Protection,
        SourcePath,
        DestinationPath,
        MappingID,
        MappingRelativePath,
        Error
    };

    MQ2WebUpdateFileType()
        : MQ2Type("WebUpdateFile")
    {
        TypeMember(Name);
        TypeMember(RepoPath);
        TypeMember(Status);
        TypeMember(Protection);

        // Created by: NeroMorte - Expose read-only file-plan details through WebUpdate.File[index].
        TypeMember(SourcePath);
        TypeMember(DestinationPath);
        TypeMember(MappingID);
        TypeMember(MappingRelativePath);
        TypeMember(Error);
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

        const FileResult* resolved = ResolveFile(VarPtr.DWord);
        if (!resolved) return false;
        const FileResult& result = *resolved;

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

        case SourcePath:
            return SetString(
                Dest,
                result.sourcePath
            );

        case DestinationPath:
            return SetString(
                Dest,
                result.destinationPath
            );

        case MappingID:
            return SetString(Dest, result.mappingId);

        case MappingRelativePath:
            return SetString(Dest, result.mappingRelativePath);

        case Error:
            return SetString(
                Dest,
                result.error
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
        const FileResult* result = ResolveFile(VarPtr.DWord);
        if (!result)
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
            result->fileName.c_str()
        );

        return true;
    }

private:
    const FileResult* ResolveFile(DWORD encoded) const
    {
        const std::size_t profileIndex =
            (static_cast<std::size_t>(encoded) >> 16) & 0xFFFF;
        const std::size_t fileIndex =
            static_cast<std::size_t>(encoded) & 0xFFFF;

        if (fileIndex == 0) return nullptr;

        if (profileIndex == 0)
        {
            return fileIndex <= g_fileResults.size()
                ? &g_fileResults[fileIndex - 1]
                : nullptr;
        }

        if (profileIndex > g_managedProfiles.size()) return nullptr;
        const auto found = g_repositoryViews.find(
            g_managedProfiles[profileIndex - 1].id);
        if (found == g_repositoryViews.end() ||
            fileIndex > found->second.fileResults.size())
            return nullptr;

        return &found->second.fileResults[fileIndex - 1];
    }

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


// Created by: NeroMorte - MQ2WebUpdate 2.0 indexed read-only profile datatype.
class MQ2WebUpdateProfileType : public MQ2Type
{
public:
    enum Members
    {
        ID = 1,
        Name,
        SourceType,
        Repository,
        Branch
    };

    MQ2WebUpdateProfileType()
        : MQ2Type("WebUpdateProfile")
    {
        TypeMember(ID);
        TypeMember(Name);
        TypeMember(SourceType);
        TypeMember(Repository);
        TypeMember(Branch);
    }

    bool GetMember(
        MQVarPtr VarPtr,
        const char* Member,
        char* Index,
        MQTypeVar& Dest) override
    {
        MQTypeMember* pMember =
            MQ2WebUpdateProfileType::FindMember(
                Member
            );

        if (!pMember)
            return false;

        const size_t profileIndex =
            static_cast<size_t>(
                VarPtr.DWord
            );

        if (profileIndex == 0 ||
            profileIndex > g_managedProfiles.size())
        {
            return false;
        }

        const profilemodel::Profile& profile =
            g_managedProfiles[profileIndex - 1];

        switch ((Members)pMember->ID)
        {
        case ID:
            return SetString(
                Dest,
                profile.id
            );

        case Name:
            return SetString(
                Dest,
                profile.name
            );

        case SourceType:
            return SetString(
                Dest,
                profilemodel::SourceProviderName(profile.provider)
            );

        case Repository:
            return SetString(
                Dest,
                std::string(profile.owner) +
                "/" +
                profile.repository
            );

        case Branch:
            return SetString(
                Dest,
                profile.reference
            );
        }

        return false;
    }

    bool ToString(
        MQVarPtr VarPtr,
        char* Destination) override
    {
        const size_t profileIndex =
            static_cast<size_t>(
                VarPtr.DWord
            );

        if (profileIndex == 0 ||
            profileIndex > g_managedProfiles.size())
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
            g_managedProfiles[profileIndex - 1].id.c_str()
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

class MQ2WebUpdateTreeFileType : public MQ2Type
{
public:
    enum Members
    {
        MappingID = 1, RepositoryPath, RelativePath, Size, Selected
    };

    MQ2WebUpdateTreeFileType() : MQ2Type("WebUpdateTreeFile")
    {
        TypeMember(MappingID); TypeMember(RepositoryPath);
        TypeMember(RelativePath); TypeMember(Size); TypeMember(Selected);
    }

    bool GetMember(MQVarPtr VarPtr, const char* Member, char* Index,
        MQTypeVar& Dest) override
    {
        MQTypeMember* member = MQ2WebUpdateTreeFileType::FindMember(Member);
        if (!member) return false;
        const std::size_t index = static_cast<std::size_t>(VarPtr.DWord);
        if (index == 0 || index > g_repositoryTree.size()) return false;
        const auto& entry = g_repositoryTree[index - 1];
        switch ((Members)member->ID)
        {
        case MappingID: return SetString(Dest, entry.mappingId);
        case RepositoryPath: return SetString(Dest, entry.repositoryPath);
        case RelativePath: return SetString(Dest, entry.mappingRelativePath);
        case Size: return SetString(Dest, std::to_string(entry.size));
        case Selected:
            Dest.DWord = entry.selected ? 1 : 0;
            Dest.Type = mq::datatypes::pBoolType;
            return true;
        }
        return false;
    }

    bool ToString(MQVarPtr VarPtr, char* Destination) override
    {
        const std::size_t index = static_cast<std::size_t>(VarPtr.DWord);
        if (index == 0 || index > g_repositoryTree.size())
        {
            strcpy_s(Destination, MAX_STRING, "NULL");
            return false;
        }
        strcpy_s(Destination, MAX_STRING,
            g_repositoryTree[index - 1].repositoryPath.c_str());
        return true;
    }

private:
    bool SetString(MQTypeVar& Dest, const std::string& value)
    {
        strcpy_s(m_buffer, sizeof(m_buffer), value.c_str());
        Dest.Ptr = m_buffer;
        Dest.Type = mq::datatypes::pStringType;
        return true;
    }
    char m_buffer[MAX_STRING] = {};
};


class MQ2WebUpdateMappingType : public MQ2Type
{
public:
    enum Members
    {
        ID = 1, Name, Enabled, Recursive, Required, RestartRequired,
        RemotePath, DestinationRoot, DestinationPath,
        IncludePatterns, ExcludePatterns, MaximumFileBytes
    };

    MQ2WebUpdateMappingType() : MQ2Type("WebUpdateMapping")
    {
        TypeMember(ID); TypeMember(Name); TypeMember(Enabled);
        TypeMember(Recursive); TypeMember(Required); TypeMember(RestartRequired);
        TypeMember(RemotePath); TypeMember(DestinationRoot); TypeMember(DestinationPath);
        TypeMember(IncludePatterns); TypeMember(ExcludePatterns);
        TypeMember(MaximumFileBytes);
    }

    bool GetMember(MQVarPtr VarPtr, const char* Member, char* Index, MQTypeVar& Dest) override
    {
        MQTypeMember* member = MQ2WebUpdateMappingType::FindMember(Member);
        if (!member) return false;

        const std::size_t profileIndex = (VarPtr.DWord >> 16) & 0xFFFF;
        const std::size_t mappingIndex = VarPtr.DWord & 0xFFFF;

        if (profileIndex == 0 || profileIndex > g_managedProfiles.size()) return false;
        const auto& profile = g_managedProfiles[profileIndex - 1];
        if (mappingIndex == 0 || mappingIndex > profile.mappings.size()) return false;
        const auto& mapping = profile.mappings[mappingIndex - 1];

        switch ((Members)member->ID)
        {
        case ID: return SetString(Dest, mapping.id);
        case Name: return SetString(Dest, mapping.name);
        case RemotePath: return SetString(Dest, mapping.remotePath);
        case DestinationRoot:
            return SetString(Dest, profilemodel::DestinationRootName(mapping.destinationRoot));
        case DestinationPath: return SetString(Dest, mapping.destinationPath);
        case IncludePatterns: return SetString(Dest, profilemodel::JoinList(mapping.includePatterns));
        case ExcludePatterns: return SetString(Dest, profilemodel::JoinList(mapping.excludePatterns));
        case MaximumFileBytes: return SetString(Dest, std::to_string(mapping.maximumFileBytes));
        case Enabled: return SetBool(Dest, mapping.enabled);
        case Recursive: return SetBool(Dest, mapping.recursive);
        case Required: return SetBool(Dest, mapping.required);
        case RestartRequired: return SetBool(Dest, mapping.restartRequired);
        }
        return false;
    }

    bool ToString(MQVarPtr VarPtr, char* Destination) override
    {
        const std::size_t profileIndex = (VarPtr.DWord >> 16) & 0xFFFF;
        const std::size_t mappingIndex = VarPtr.DWord & 0xFFFF;
        if (profileIndex == 0 || profileIndex > g_managedProfiles.size() ||
            mappingIndex == 0 || mappingIndex > g_managedProfiles[profileIndex - 1].mappings.size())
        {
            strcpy_s(Destination, MAX_STRING, "NULL");
            return false;
        }
        strcpy_s(Destination, MAX_STRING,
            g_managedProfiles[profileIndex - 1].mappings[mappingIndex - 1].id.c_str());
        return true;
    }

private:
    bool SetString(MQTypeVar& Dest, const std::string& value)
    {
        strcpy_s(m_buffer, sizeof(m_buffer), value.c_str());
        Dest.Ptr = m_buffer;
        Dest.Type = mq::datatypes::pStringType;
        return true;
    }
    bool SetBool(MQTypeVar& Dest, bool value)
    {
        Dest.DWord = value ? 1 : 0;
        Dest.Type = mq::datatypes::pBoolType;
        return true;
    }
    char m_buffer[MAX_STRING] = {};
};


class MQ2WebUpdateManagedProfileType : public MQ2Type
{
public:
    enum Members
    {
        ID = 1, Name, Role, Provider, Enabled, Private, CredentialStored,
        Owner, Repository, Reference, Channel, MappingCount, Mapping,
        MonitorStatus, MonitorSHA, MonitorError, MonitorLastChecked,
        MonitorOnStartup, MonitorIntervalMinutes, NotificationsEnabled,
        AcknowledgedSHA,
        PlanStatus, PlanSHA, PlanError, PlanLastChecked,
        PlanFileCount, PlanSameCount, PlanUpdateCount, PlanMissingCount,
        PlanProtectedCount, PlanErrorCount, PlanUpdateAvailable, PlanFile
    };

    MQ2WebUpdateManagedProfileType() : MQ2Type("WebUpdateManagedProfile")
    {
        TypeMember(ID); TypeMember(Name); TypeMember(Role); TypeMember(Provider); TypeMember(Enabled);
        TypeMember(Private); TypeMember(CredentialStored); TypeMember(Owner);
        TypeMember(Repository); TypeMember(Reference); TypeMember(Channel);
        TypeMember(MappingCount); TypeMember(Mapping);
        TypeMember(MonitorStatus); TypeMember(MonitorSHA);
        TypeMember(MonitorError); TypeMember(MonitorLastChecked);
        TypeMember(MonitorOnStartup); TypeMember(MonitorIntervalMinutes);
        TypeMember(NotificationsEnabled); TypeMember(AcknowledgedSHA);
        TypeMember(PlanStatus); TypeMember(PlanSHA); TypeMember(PlanError);
        TypeMember(PlanLastChecked); TypeMember(PlanFileCount);
        TypeMember(PlanSameCount); TypeMember(PlanUpdateCount);
        TypeMember(PlanMissingCount); TypeMember(PlanProtectedCount);
        TypeMember(PlanErrorCount); TypeMember(PlanUpdateAvailable);
        TypeMember(PlanFile);
    }

    bool GetMember(MQVarPtr VarPtr, const char* Member, char* Index, MQTypeVar& Dest) override
    {
        MQTypeMember* member = MQ2WebUpdateManagedProfileType::FindMember(Member);
        if (!member) return false;
        const std::size_t profileIndex = static_cast<std::size_t>(VarPtr.DWord);
        if (profileIndex == 0 || profileIndex > g_managedProfiles.size()) return false;
        const auto& profile = g_managedProfiles[profileIndex - 1];

        switch ((Members)member->ID)
        {
        case ID: return SetString(Dest, profile.id);
        case Name: return SetString(Dest, profile.name);
        case Role: return SetString(Dest, profilemodel::ProfileRoleName(profile.role));
        case Provider: return SetString(Dest, profilemodel::SourceProviderName(profile.provider));
        case Owner: return SetString(Dest, profile.owner);
        case Repository: return SetString(Dest, profile.repository);
        case Reference: return SetString(Dest, profile.reference);
        case Channel: return SetString(Dest, profile.channel);
        case AcknowledgedSHA: return SetString(Dest, profile.acknowledgedSha);
        case MonitorOnStartup: return SetBool(Dest, profile.monitorOnStartup);
        case NotificationsEnabled: return SetBool(Dest, profile.notificationsEnabled);
        case MonitorIntervalMinutes:
            Dest.DWord = profile.monitorIntervalMinutes;
            Dest.Type = mq::datatypes::pIntType;
            return true;
        case MonitorStatus:
        case MonitorSHA:
        case MonitorError:
        case MonitorLastChecked:
        {
            const auto found = g_monitorStates.find(profile.id);
            if (found == g_monitorStates.end())
                return SetString(Dest, member->ID == MonitorStatus ? "Not Checked" : "");
            if (member->ID == MonitorStatus) return SetString(Dest, found->second.status);
            if (member->ID == MonitorSHA) return SetString(Dest, found->second.remoteSha);
            if (member->ID == MonitorError) return SetString(Dest, found->second.lastError);
            return SetString(Dest, found->second.lastChecked);
        }
        case PlanStatus:
        case PlanSHA:
        case PlanError:
        case PlanLastChecked:
        {
            const auto found = g_repositoryViews.find(profile.id);
            if (found == g_repositoryViews.end())
                return SetString(Dest, member->ID == PlanStatus ? "Not Checked" : "");
            if (member->ID == PlanStatus) return SetString(Dest, found->second.status);
            if (member->ID == PlanSHA) return SetString(Dest, found->second.remoteSha);
            if (member->ID == PlanError) return SetString(Dest, found->second.lastError);
            return SetString(Dest, found->second.lastChecked);
        }
        case PlanFileCount:
        case PlanSameCount:
        case PlanUpdateCount:
        case PlanMissingCount:
        case PlanProtectedCount:
        case PlanErrorCount:
        {
            const auto found = g_repositoryViews.find(profile.id);
            std::size_t value = 0;
            if (found != g_repositoryViews.end())
            {
                if (member->ID == PlanFileCount) value = found->second.fileResults.size();
                else if (member->ID == PlanSameCount) value = found->second.sameCount;
                else if (member->ID == PlanUpdateCount) value = found->second.updateCount;
                else if (member->ID == PlanMissingCount) value = found->second.missingCount;
                else if (member->ID == PlanProtectedCount) value = found->second.protectedCount;
                else value = found->second.errorCount;
            }
            Dest.DWord = static_cast<DWORD>(value);
            Dest.Type = mq::datatypes::pIntType;
            return true;
        }
        case PlanUpdateAvailable:
        {
            const auto found = g_repositoryViews.find(profile.id);
            const bool available = found != g_repositoryViews.end() &&
                (found->second.updateCount > 0 || found->second.missingCount > 0);
            return SetBool(Dest, available);
        }
        case PlanFile:
        {
            if (!Index || !Index[0]) return false;
            const int requested = atoi(Index);
            const auto found = g_repositoryViews.find(profile.id);
            if (requested <= 0 || requested > 0xFFFF ||
                profileIndex > 0xFFFF || found == g_repositoryViews.end() ||
                static_cast<std::size_t>(requested) > found->second.fileResults.size())
                return false;
            Dest.DWord = static_cast<DWORD>((profileIndex << 16) |
                static_cast<std::size_t>(requested));
            Dest.Type = pWebUpdateFileType;
            return true;
        }
        case Enabled: return SetBool(Dest, profile.enabled);
        case Private: return SetBool(Dest, profile.privateRepository);
        case CredentialStored:
#ifdef _WIN32
            return SetBool(Dest,
                mq2webupdate::credentials::HasGitHubToken(profile.id) ||
                mq2webupdate::credentials::HasGitHubToken(
                    kGlobalGitHubCredentialId));
#else
            return SetBool(Dest, false);
#endif
        case MappingCount:
            Dest.DWord = static_cast<DWORD>(profile.mappings.size());
            Dest.Type = mq::datatypes::pIntType;
            return true;
        case Mapping:
        {
            if (!Index || !Index[0]) return false;
            const int requested = atoi(Index);
            if (requested <= 0 || requested > 0xFFFF ||
                static_cast<std::size_t>(requested) > profile.mappings.size() ||
                profileIndex > 0xFFFF) return false;
            Dest.DWord = static_cast<DWORD>((profileIndex << 16) |
                static_cast<std::size_t>(requested));
            Dest.Type = pWebUpdateMappingType;
            return true;
        }
        }
        return false;
    }

    bool ToString(MQVarPtr VarPtr, char* Destination) override
    {
        const std::size_t profileIndex = static_cast<std::size_t>(VarPtr.DWord);
        if (profileIndex == 0 || profileIndex > g_managedProfiles.size())
        {
            strcpy_s(Destination, MAX_STRING, "NULL");
            return false;
        }
        strcpy_s(Destination, MAX_STRING, g_managedProfiles[profileIndex - 1].id.c_str());
        return true;
    }

private:
    bool SetString(MQTypeVar& Dest, const std::string& value)
    {
        strcpy_s(m_buffer, sizeof(m_buffer), value.c_str());
        Dest.Ptr = m_buffer;
        Dest.Type = mq::datatypes::pStringType;
        return true;
    }
    bool SetBool(MQTypeVar& Dest, bool value)
    {
        Dest.DWord = value ? 1 : 0;
        Dest.Type = mq::datatypes::pBoolType;
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
        // Created by: NeroMorte - MQ2WebUpdate 2.0 public API members.
        Version,
        ApiVersion,
        Phase,
        Busy,
        Progress,
        StageReady,
        RestartRequired,
        // Created by: NeroMorte - MQ2WebUpdate 2.0 generic profile API.
        Profile,
        ProfileCount,
        ActiveProfile,
        SourceType,
        ConfigurationLoaded,
        ConfigurationPath,
        ConfigurationError,
        AutoCheckOnLoad,
        AutoUpstreamOnLoad,
        AutoMonitorOnLoad,
        AutoCheckIntervalMinutes,
        NetworkTimeoutSeconds,
        NetworkRetryCount,
        ProfileTransferPath,
        DiagnosticsPath,
        GlobalGitHubCredentialStored,
        ManagedProfile,
        ManagedProfileCount,
        ProfileStorePath,
        ProfileStoreError,
        RemoteSHA,
        Repository,
        Branch,
        UpstreamSHA,
        UpstreamStatus,
        UpstreamLastError,
        LastError,
        FileCount,
        SameCount,
        UpdateCount,
        MissingCount,
        ProtectedCount,
        ErrorCount,
        UpdateAvailable,
        File,
        TreeFileCount,
        TreeFile
    };

    MQ2WebUpdateType()
        : MQ2Type("WebUpdate")
    {
        TypeMember(Status);

        // Created by: NeroMorte - MQ2WebUpdate 2.0 public API members.
        TypeMember(Version);
        TypeMember(ApiVersion);
        TypeMember(Phase);
        TypeMember(Busy);
        TypeMember(Progress);
        TypeMember(StageReady);
        TypeMember(RestartRequired);
        // Created by: NeroMorte - MQ2WebUpdate 2.0 generic profile API.
        TypeMember(Profile);
        TypeMember(ProfileCount);
        TypeMember(ActiveProfile);
        TypeMember(SourceType);
        TypeMember(ConfigurationLoaded);
        TypeMember(ConfigurationPath);
        TypeMember(ConfigurationError);
        TypeMember(AutoCheckOnLoad);
        TypeMember(AutoUpstreamOnLoad);
        TypeMember(AutoMonitorOnLoad);
        TypeMember(AutoCheckIntervalMinutes);
        TypeMember(NetworkTimeoutSeconds);
        TypeMember(NetworkRetryCount);
        TypeMember(ProfileTransferPath);
        TypeMember(DiagnosticsPath);
        TypeMember(GlobalGitHubCredentialStored);
        TypeMember(ManagedProfile);
        TypeMember(ManagedProfileCount);
        TypeMember(ProfileStorePath);
        TypeMember(ProfileStoreError);

        TypeMember(RemoteSHA);
        TypeMember(Repository);
        TypeMember(Branch);
        TypeMember(UpstreamSHA);
        TypeMember(UpstreamStatus);
        TypeMember(UpstreamLastError);
        TypeMember(LastError);

        TypeMember(FileCount);
        TypeMember(SameCount);
        TypeMember(UpdateCount);
        TypeMember(MissingCount);
        TypeMember(ProtectedCount);
        TypeMember(ErrorCount);

        TypeMember(UpdateAvailable);
        TypeMember(File);
        TypeMember(TreeFileCount);
        TypeMember(TreeFile);
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

        // Created by: NeroMorte - MQ2WebUpdate 2.0 public API values.
        case Version:
            return SetString(
                Dest,
                kWebUpdateVersion
            );

        case ApiVersion:
            return SetString(
                Dest,
                kWebUpdateApiVersion
            );

        case Phase:
            return SetString(
                Dest,
                g_phase
            );

        case Busy:
            Dest.DWord =
                (g_compareRunning.load() ||
                 g_upstreamRunning.load() ||
                 g_monitorRunning.load() ||
                 g_status == "Scanning" ||
                 g_status == "Comparing" ||
                 g_status == "Staging" ||
                 g_status == "Applying")
                    ? 1
                    : 0;

            Dest.Type =
                mq::datatypes::pBoolType;

            return true;

        case Progress:
            Dest.DWord =
                static_cast<DWORD>(
                    g_progress
                );

            Dest.Type =
                mq::datatypes::pIntType;

            return true;

        case StageReady:
            Dest.DWord =
                g_stageReady
                    ? 1
                    : 0;

            Dest.Type =
                mq::datatypes::pBoolType;

            return true;

        case RestartRequired:
            Dest.DWord =
                g_restartRequired
                    ? 1
                    : 0;

            Dest.Type =
                mq::datatypes::pBoolType;

            return true;
                // Created by: NeroMorte - MQ2WebUpdate 2.0 generic profile API.
        case Profile:
        {
            // Created by: NeroMorte - Preserve Profile with no index as the
            // active profile while exposing Profile[index] as profile metadata.
            if (!Index ||
                !Index[0])
            {
                const auto* main = GetManagedMainProfile();
                return SetString(Dest, main ? main->id : "");
            }

            const int requested =
                atoi(Index);

            if (requested <= 0 ||
                static_cast<size_t>(
                    requested
                ) >
                    g_managedProfiles.size())
            {
                return false;
            }

            Dest.DWord =
                static_cast<DWORD>(
                    requested
                );

            Dest.Type =
                pWebUpdateProfileType;

            return true;
        }

        case ProfileCount:
            Dest.DWord =
                static_cast<DWORD>(
                    g_managedProfiles.size()
                );

            Dest.Type =
                mq::datatypes::pIntType;

            return true;

        case ActiveProfile:
        {
            const auto* main = GetManagedMainProfile();
            return SetString(Dest, main ? main->id : "");
        }

        case SourceType:
        {
            const auto* main = GetManagedMainProfile();
            return SetString(Dest, main
                ? profilemodel::SourceProviderName(main->provider) : "");
        }

        case ConfigurationLoaded:
            Dest.DWord = g_configurationLoaded ? 1 : 0;
            Dest.Type = mq::datatypes::pBoolType;
            return true;

        case ManagedProfile:
        {
            if (!Index || !Index[0]) return false;
            const int requested = atoi(Index);
            if (requested <= 0 ||
                static_cast<std::size_t>(requested) > g_managedProfiles.size())
                return false;
            Dest.DWord = static_cast<DWORD>(requested);
            Dest.Type = pWebUpdateManagedProfileType;
            return true;
        }

        case ManagedProfileCount:
            Dest.DWord = static_cast<DWORD>(g_managedProfiles.size());
            Dest.Type = mq::datatypes::pIntType;
            return true;

        case ProfileStorePath:
            return SetString(Dest, g_profileStorePath);

        case ProfileStoreError:
            return SetString(Dest, g_profileStoreError);

        case ConfigurationPath:
            return SetString(Dest, g_configurationPath);

        case ConfigurationError:
            return SetString(Dest, g_configurationError);

        case AutoCheckOnLoad:
            Dest.DWord = g_autoCheckOnLoad ? 1 : 0;
            Dest.Type = mq::datatypes::pBoolType;
            return true;

        case AutoUpstreamOnLoad:
            Dest.DWord = g_autoUpstreamOnLoad ? 1 : 0;
            Dest.Type = mq::datatypes::pBoolType;
            return true;

        case AutoMonitorOnLoad:
            Dest.DWord = g_autoMonitorOnLoad ? 1 : 0;
            Dest.Type = mq::datatypes::pBoolType;
            return true;

        case AutoCheckIntervalMinutes:
            Dest.DWord = static_cast<DWORD>(g_autoCheckIntervalMinutes);
            Dest.Type = mq::datatypes::pIntType;
            return true;

        case NetworkTimeoutSeconds:
            Dest.DWord = static_cast<DWORD>(g_networkTimeoutSeconds);
            Dest.Type = mq::datatypes::pIntType;
            return true;

        case NetworkRetryCount:
            Dest.DWord = static_cast<DWORD>(g_networkRetryCount);
            Dest.Type = mq::datatypes::pIntType;
            return true;

        case ProfileTransferPath:
            return SetString(Dest, GetProfileTransferPath().string());

        case DiagnosticsPath:
            return SetString(Dest, GetDiagnosticsPath().string());

        case GlobalGitHubCredentialStored:
#ifdef _WIN32
            Dest.DWord = mq2webupdate::credentials::HasGitHubToken(
                kGlobalGitHubCredentialId) ? 1 : 0;
#else
            Dest.DWord = 0;
#endif
            Dest.Type = mq::datatypes::pBoolType;
            return true;

case RemoteSHA:
            return SetString(
                Dest,
                g_remoteSha
            );

        case Repository:
        {
            const auto* main = GetManagedMainProfile();
            return SetString(Dest, main
                ? main->owner + "/" + main->repository : "");
        }

        case Branch:
        {
            const auto* main = GetManagedMainProfile();
            return SetString(Dest, main ? main->reference : "");
        }

        case UpstreamSHA:
            return SetString(
                Dest,
                g_upstreamSha
            );

        case UpstreamStatus:
            return SetString(
                Dest,
                g_upstreamStatus
            );

        case UpstreamLastError:
            return SetString(
                Dest,
                g_upstreamLastError
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

        case TreeFileCount:
            Dest.DWord = static_cast<DWORD>(g_repositoryTree.size());
            Dest.Type = mq::datatypes::pIntType;
            return true;

        case TreeFile:
        {
            if (!Index || !Index[0]) return false;
            const int requested = atoi(Index);
            if (requested <= 0 ||
                static_cast<std::size_t>(requested) > g_repositoryTree.size())
                return false;
            Dest.DWord = static_cast<DWORD>(requested);
            Dest.Type = pWebUpdateTreeFileType;
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

        const auto* profile = GetManagedMainProfile();
        if (profile)
            WriteChatf("\ay[MQ2WebUpdate]\ax Main Download: %s (%s/%s @ %s)",
                profile->id.c_str(), profile->owner.c_str(),
                profile->repository.c_str(), profile->reference.c_str());

        WriteChatf(
            "\ay[MQ2WebUpdate]\ax Automation: Main load %s, Monitor load %s, upstream %s, interval %d minute(s)",
            g_autoCheckOnLoad ? "ON" : "OFF",
            g_autoMonitorOnLoad ? "ON" : "OFF",
            g_autoUpstreamOnLoad ? "ON" : "OFF",
            g_autoCheckIntervalMinutes
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
        // Created by: NeroMorte - MQ2WebUpdate 3.0 product identity and concise help header.
        WriteChatf(
            "\ag[MQ2WebUpdate v%s]\ax Created by: NeroMorte",
            kWebUpdateVersion
        );

        WriteChatf(
            "\ay[MQ2WebUpdate]\ax Safe transactional updater backend for MacroQuest deployments."
        );

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
            "\at/webupdate monitors\ax - Check all Monitor Only repositories"
        );

        WriteChatf(
            "\at/webupdate profiles export|import\ax - Transfer repository profiles without credentials"
        );

        WriteChatf(
            "\at/webupdate dll prepare <mapping-id>\ax - Verify and prepare a staged plugin DLL for the independent Lua handoff"
        );

        WriteChatf(
            "\at/webupdate setting <name> <value>\ax - Save an automation setting"
        );

        WriteChatf(
            "\at/webupdate config reset\ax - Restore safe configuration defaults"
        );

        WriteChatf(
            "\at/webupdate diagnostics export\ax - Write a sanitized diagnostics report"
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
            error = GitHubHttpError(response);

            return false;
        }

        return true;
    }

    bool BuildMappedRemoteFiles(
        const profilemodel::Profile& profile,
        const std::string& treeJson,
        std::vector<RemoteFile>& output,
        std::vector<mq2webupdate::planner::BrowserEntry>& browser,
        mq2webupdate::planner::PlanPurpose purpose,
        std::string& error)
    {
        std::vector<mq2webupdate::planner::RemoteTreeFile> tree;
        if (!mq2webupdate::providers::ParseGitHubTreeResponse(
                treeJson, tree, error))
        {
            return false;
        }

        const auto plan =
            mq2webupdate::planner::BuildPlan(profile, tree, purpose);
        browser = mq2webupdate::planner::BuildBrowserEntries(profile, tree);
        if (!plan.IsValid())
        {
            error = "Repository deployment plan was rejected: " +
                plan.errors.front();
            return false;
        }

        output.clear();
        output.reserve(plan.items.size());
        for (const auto& item : plan.items)
        {
            RemoteFile remote;
            remote.repoPath = item.repositoryPath;
            remote.fileName = item.destinationRelativePath;
            remote.mappingId = item.mappingId;
            const std::string stagePrefix = item.mappingId + "/";
            remote.mappingRelativePath =
                item.stageRelativePath.rfind(stagePrefix, 0) == 0
                    ? item.stageRelativePath.substr(stagePrefix.size())
                    : item.destinationRelativePath;
            remote.stageRelativePath = item.stageRelativePath;
            remote.destinationRoot = item.destinationRoot;
            remote.destinationRelativePath = item.destinationRelativePath;
            remote.expectedSize = item.expectedSize;
            remote.gitObjectSha = item.gitObjectSha;
            remote.restartRequired = item.restartRequired;
            output.push_back(std::move(remote));
        }
        return true;
    }

    std::string MonitorTimestamp()
    {
        const std::time_t now = std::time(nullptr);
        std::tm local = {};
        if (localtime_s(&local, &now) != 0) return "unknown";
        std::ostringstream output;
        output << std::put_time(&local, "%Y-%m-%d %H:%M:%S");
        return output.str();
    }

    CompareWorkerResult RunCompareWorker(
        const profilemodel::Profile& profile);

    ManagedRepositoryView BuildRepositoryView(
        const CompareWorkerResult& comparison,
        const std::string& checkedAt)
    {
        ManagedRepositoryView view;
        view.status = comparison.status.empty()
            ? (comparison.success ? "Up To Date" : "Compare Error")
            : comparison.status;
        view.remoteSha = comparison.remoteSha;
        view.lastError = comparison.lastError;
        view.lastChecked = checkedAt;
        view.fileResults = comparison.fileResults;
        view.sameCount = comparison.sameCount;
        view.updateCount = comparison.updateCount;
        view.missingCount = comparison.missingCount;
        view.protectedCount = comparison.protectedCount;
        view.errorCount = comparison.errorCount;
        return view;
    }

    void ManagedMonitorWorkerMain(
        std::vector<profilemodel::Profile> profiles)
    {
        ManagedMonitorWorkerResult result;

        for (const auto& profile : profiles)
        {
            ManagedMonitorState state;
            state.status = "Checking";
            state.lastChecked = MonitorTimestamp();
            CompareWorkerResult comparison = RunCompareWorker(profile);
            state.remoteSha = comparison.remoteSha;
            state.lastError = comparison.lastError;
            state.status = comparison.success ? "Online" : "Error";
            result.views[profile.id] =
                BuildRepositoryView(comparison, state.lastChecked);
            result.states[profile.id] = std::move(state);
        }

        {
            std::lock_guard<std::mutex> lock(g_monitorMutex);
            g_monitorCompletedResult = std::move(result);
            g_monitorResultReady = true;
        }
        g_monitorRunning.store(false);
    }

    bool StartManagedMonitorCheck(const std::string& profileId = {})
    {
        if (g_monitorRunning.load()) return false;
        if (g_monitorThread.joinable()) g_monitorThread.join();

        std::vector<profilemodel::Profile> profiles;
        for (const auto& profile : g_managedProfiles)
        {
            const bool explicitlyRequested =
                !profileId.empty() && profile.id == profileId;
            if (profile.enabled &&
                (explicitlyRequested ||
                 (profileId.empty() &&
                  profile.role == profilemodel::ProfileRole::MonitorOnly)))
                profiles.push_back(profile);
        }

        if (!profileId.empty() && profiles.empty()) return false;

        {
            std::lock_guard<std::mutex> lock(g_monitorMutex);
            g_monitorResultReady = false;
            g_monitorCompletedResult = ManagedMonitorWorkerResult{};
        }

        const std::string startedAt = MonitorTimestamp();
        for (const auto& profile : profiles)
        {
            auto& state = g_monitorStates[profile.id];
            state.status = "Checking";
            state.remoteSha.clear();
            state.lastError.clear();
            state.lastChecked = startedAt;

            auto& view = g_repositoryViews[profile.id];
            view = ManagedRepositoryView{};
            view.status = "Checking";
            view.lastChecked = startedAt;
        }

        g_monitorRunning.store(true);
        try
        {
            g_monitorThread = std::thread(
                ManagedMonitorWorkerMain, std::move(profiles));
        }
        catch (...)
        {
            g_monitorRunning.store(false);
            return false;
        }
        return true;
    }

    void PublishManagedMonitorResults()
    {
        ManagedMonitorWorkerResult result;
        {
            std::lock_guard<std::mutex> lock(g_monitorMutex);
            if (!g_monitorResultReady) return;
            result = std::move(g_monitorCompletedResult);
            g_monitorResultReady = false;
        }
        for (auto& entry : result.states)
        {
            const std::string id = entry.first;
            g_monitorStates[id] = std::move(entry.second);
            const auto view = result.views.find(id);
            if (view != result.views.end())
                g_repositoryViews[id] = std::move(view->second);
            const auto* profile = FindManagedProfile(id);
            if (profile && profile->monitorIntervalMinutes > 0)
            {
                g_monitorNextCheck[id] = std::chrono::steady_clock::now() +
                    std::chrono::minutes(profile->monitorIntervalMinutes);
            }
            if (profile && profile->notificationsEnabled &&
                g_monitorStates[id].status == "Online" &&
                !profile->acknowledgedSha.empty() &&
                profile->acknowledgedSha != g_monitorStates[id].remoteSha)
            {
                WriteChatf(
                    "\ay[MQ2WebUpdate]\ax Monitor update detected: %s (%s/%s @ %s)",
                    profile->name.c_str(), profile->owner.c_str(),
                    profile->repository.c_str(), profile->reference.c_str());
            }

            if (profile)
            {
                const auto published = g_repositoryViews.find(id);
                if (published != g_repositoryViews.end())
                {
                    if (published->second.errorCount == 0)
                    {
                        WriteChatf(
                            "\ag[MQ2WebUpdate]\ax Repository check complete: %s - %s (%zu files, %zu updates, %zu new).",
                            profile->name.c_str(), published->second.status.c_str(),
                            published->second.fileResults.size(),
                            published->second.updateCount,
                            published->second.missingCount);
                    }
                    else
                    {
                        WriteChatf(
                            "\ar[MQ2WebUpdate]\ax Repository check failed: %s - %s (%zu errors).",
                            profile->name.c_str(), published->second.status.c_str(),
                            published->second.errorCount);
                    }
                }
            }
        }
    }

    CompareWorkerResult RunCompareWorker(
        const profilemodel::Profile& profile)
    {
        CompareWorkerResult output;
        output.status = "Compare Error";

        // --------------------------------------------------------
        // 1. Resolve the exact remote commit.
        // --------------------------------------------------------

        const auto provider =
            mq2webupdate::providers::CreateProviderAdapter(profile.provider);

        if (!provider)
        {
            output.lastError = "The repository provider is not supported.";
            ++output.errorCount;
            return output;
        }

        mq2webupdate::credentials::ScopedSecret credential;
        if (!ReadOptionalGitHubCredential(
                profile, credential, output.lastError))
        {
            ++output.errorCount;
            return output;
        }

        const std::string commitUrl =
            provider->ResolveReferenceRequest(profile).url;

        auto commitResponse = GitHubProviderGet(
            commitUrl, credential.value, false);

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

        std::string treeJson;
        const std::string cacheKey = RepositoryCacheKey(profile);
        {
            std::lock_guard<std::mutex> cacheLock(g_repositoryTreeCacheMutex);
            const auto cached = g_repositoryTreeCache.find(cacheKey);
            if (cached != g_repositoryTreeCache.end() &&
                cached->second.commitSha == output.remoteSha)
            {
                treeJson = cached->second.json;
            }
        }

        if (treeJson.empty())
        {
            const std::string treeUrl =
                provider->RepositoryTreeRequest(profile, output.remoteSha).url;
            auto treeResponse = GitHubProviderGet(
                treeUrl, credential.value, false);
            if (!WorkerCheckResponse(treeResponse, output.lastError))
            {
                ++output.errorCount;
                return output;
            }
            treeJson = std::move(treeResponse.text);
            std::lock_guard<std::mutex> cacheLock(g_repositoryTreeCacheMutex);
            g_repositoryTreeCache[cacheKey] = { output.remoteSha, treeJson };
        }

        const std::string luaPrefix = LuaRemotePrefix(profile);
        const std::string pathNeedle = "\"path\"";
        size_t pos = 0;

        while (true)
        {
            pos =
                treeJson.find(
                    pathNeedle,
                    pos
                );

            if (pos == std::string::npos)
                break;

            auto colonPos =
                treeJson.find(
                    ':',
                    pos + pathNeedle.size()
                );

            if (colonPos == std::string::npos)
                break;

            auto firstQuote =
                treeJson.find(
                    '"',
                    colonPos + 1
                );

            if (firstQuote == std::string::npos)
                break;

            auto secondQuote =
                treeJson.find(
                    '"',
                    firstQuote + 1
                );

            if (secondQuote == std::string::npos)
                break;

            std::string path =
                treeJson.substr(
                    firstQuote + 1,
                    secondQuote - firstQuote - 1
                );

            if (!luaPrefix.empty() && path.rfind(luaPrefix, 0) == 0)
            {
                std::string relative =
                    path.substr(
                        luaPrefix.size()
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

        if (!BuildMappedRemoteFiles(
                profile,
                treeJson,
                output.remoteFiles,
                output.repositoryTree,
                mq2webupdate::planner::PlanPurpose::ReadOnlyComparison,
                output.lastError))
        {
            ++output.errorCount;
            return output;
        }

        if (output.remoteFiles.empty())
        {
            output.lastError =
                "The Main Download repository mappings selected no files.";

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

        const fs::path runtimeRoot =
            luaDirectory.parent_path();

        // --------------------------------------------------------
        // 4. Compare local Git blob SHAs with the immutable remote tree.
        //
        // IMPORTANT:
        // Everything here belongs only to 'output'. We do NOT
        // modify the WebUpdate TLO globals from this thread.
        // --------------------------------------------------------

        for (const auto& remote : output.remoteFiles)
        {
            FileResult result;
            result.fileName =
                std::string(profilemodel::DestinationRootName(
                    remote.destinationRoot)) + "/" +
                remote.destinationRelativePath;
            result.repoPath = remote.repoPath;
            result.mappingId = remote.mappingId;
            result.mappingRelativePath = remote.mappingRelativePath;

            // Created by: NeroMorte - Publish the repository source path in the read-only plan.
            result.sourcePath = remote.repoPath;
            result.status = "UNKNOWN";
            result.protection = "UNKNOWN";

            const fs::path destinationRoot =
                profilemodel::ResolveDestinationRoot(
                    runtimeRoot, remote.destinationRoot);
            fs::path localPath =
                destinationRoot / remote.destinationRelativePath;

            result.destinationPath =
                localPath.string();

            std::error_code ec;

            // Created by: NeroMorte - Classify the destination object before
            // following its target so dangling symbolic links remain protected.
            const bool localProtected =
                IsReparsePoint(localPath);

            const bool exists =
                fs::exists(localPath, ec);

            if (ec)
            {
                ++output.errorCount;

                result.status = "ERROR";
                result.protection = "UNKNOWN";

                // Created by: NeroMorte - Preserve the actual filesystem diagnostic per planned file.
                result.error =
                    std::string(
                        "Local destination path check failed: "
                    ) + ec.message();

                output.fileResults.push_back(
                    std::move(result)
                );

                continue;
            }

            if (!exists && !localProtected)
            {
                ++output.missingCount;

                result.status = "MISSING";
                result.protection = "NEW FILE";

                output.fileResults.push_back(
                    std::move(result)
                );

                continue;
            }

            if (localProtected)
            {
                result.protection =
                    "LINK PROTECTED";

                ++output.protectedCount;

                // Protected destinations are reported but never followed or
                // downloaded during a read-only comparison.
                result.status = "PROTECTED";
                output.fileResults.push_back(std::move(result));
                continue;
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

                // Created by: NeroMorte - Publish the existing local read failure per planned file.
                result.error =
                    "Failed to read local destination file.";

                output.fileResults.push_back(
                    std::move(result)
                );

                continue;
            }

            const std::string normalizedLocal =
                IsTextDeployment(remote.destinationRelativePath)
                    ? NormalizeTextLineEndings(localData) : localData;
            const std::string localGitSha =
                ComputeGitBlobSha(normalizedLocal);

            if (localGitSha.empty())
            {
                ++output.errorCount;
                result.status = "ERROR";
                result.error = "Failed to calculate local Git blob SHA.";
                if (output.lastError.empty()) output.lastError = result.error;
            }
            else if (localGitSha == remote.gitObjectSha)
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

    CompareWorkerResult RunStageWorker(
        const profilemodel::Profile& profile)
    {
        CompareWorkerResult output;
        output.operation = "stage";
        output.status = "Stage Error";

        // --------------------------------------------------------
        // 1. Resolve exact remote SHA.
        // --------------------------------------------------------

        const auto provider =
            mq2webupdate::providers::CreateProviderAdapter(profile.provider);

        if (!provider)
        {
            output.lastError = "The repository provider is not supported.";
            ++output.errorCount;
            return output;
        }

        mq2webupdate::credentials::ScopedSecret credential;
        if (!ReadOptionalGitHubCredential(
                profile, credential, output.lastError))
        {
            ++output.errorCount;
            return output;
        }

        const std::string commitUrl =
            provider->ResolveReferenceRequest(profile).url;

        auto commitResponse = GitHubProviderGet(
            commitUrl, credential.value, false);

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
            provider->RepositoryTreeRequest(profile, output.remoteSha).url;

        auto treeResponse = GitHubProviderGet(
            treeUrl, credential.value, false);

        if (!WorkerCheckResponse(
                treeResponse,
                output.lastError))
        {
            ++output.errorCount;
            return output;
        }

        const std::string luaPrefix = LuaRemotePrefix(profile);
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

            if (!luaPrefix.empty() && path.rfind(luaPrefix, 0) == 0)
            {
                std::string relative =
                    path.substr(
                        luaPrefix.size()
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

        if (!BuildMappedRemoteFiles(
                profile,
                treeResponse.text,
                output.remoteFiles,
                output.repositoryTree,
                mq2webupdate::planner::PlanPurpose::Install,
                output.lastError))
        {
            ++output.errorCount;
            return output;
        }

        if (output.remoteFiles.empty())
        {
            output.lastError =
                "The Main Download repository mappings selected no files.";

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
            profile.id;

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

        std::vector<mq2webupdate::planner::PlanItem> stagedPlanItems;

        for (const auto& remote : output.remoteFiles)
        {
            FileResult result;
            result.fileName =
                std::string(profilemodel::DestinationRootName(
                    remote.destinationRoot)) + "/" +
                remote.destinationRelativePath;
            result.repoPath = remote.repoPath;
            result.mappingId = remote.mappingId;
            result.mappingRelativePath = remote.mappingRelativePath;
            result.status = "UNKNOWN";
            result.protection = "UNKNOWN";

            const fs::path destinationRoot =
                profilemodel::ResolveDestinationRoot(
                    runtimeRoot, remote.destinationRoot);
            fs::path localPath =
                destinationRoot /
                remote.destinationRelativePath;

            fs::path stagePath =
                stageDirectory /
                remote.stageRelativePath;

            std::error_code ec;

            // Created by: NeroMorte - Classify the destination object before
            // following its target so dangling symbolic links remain protected.
            const bool localProtected =
                IsReparsePoint(localPath);

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

            const auto request = provider->FileRequest(
                profile, output.remoteSha, remote.repoPath);
            auto response = GitHubProviderGet(
                request.url, credential.value, true);

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

            if (response.text.size() != remote.expectedSize)
            {
                ++output.errorCount;
                result.status = "ERROR";
                if (output.lastError.empty())
                    output.lastError = "Downloaded file size does not match the resolved GitHub tree.";
                output.fileResults.push_back(std::move(result));
                continue;
            }

            // Created by: NeroMorte - A protected destination object with
            // no reachable target is not a missing file and must not be staged.
            if (localProtected && !localExists)
            {
                result.status = "PROTECTED";

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

                const bool sameBytes =
                    IsTextDeployment(remote.destinationRelativePath)
                        ? NormalizeTextLineEndings(localData) ==
                            NormalizeTextLineEndings(response.text)
                        : localData == response.text;
                if (sameBytes)
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

            mq2webupdate::planner::PlanItem stagedItem;
            stagedItem.profileId = profile.id;
            stagedItem.mappingId = remote.mappingId;
            stagedItem.repositoryPath = remote.repoPath;
            stagedItem.stageRelativePath = remote.stageRelativePath;
            stagedItem.destinationRoot = remote.destinationRoot;
            stagedItem.destinationRelativePath = remote.destinationRelativePath;
            stagedItem.expectedSize = remote.expectedSize;
            stagedItem.gitObjectSha = remote.gitObjectSha;
            stagedItem.restartRequired = remote.restartRequired;
            stagedPlanItems.push_back(std::move(stagedItem));
            output.restartRequired =
                output.restartRequired || remote.restartRequired;

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

        mq2webupdate::stageplan::Manifest stageManifest;
        stageManifest.profileId = profile.id;
        stageManifest.provider = profile.provider;
        stageManifest.owner = profile.owner;
        stageManifest.repository = profile.repository;
        stageManifest.reference = profile.reference;
        stageManifest.commitSha = output.remoteSha;
        stageManifest.items = stagedPlanItems;

        if (!WriteStageMetadata(
                metadataPath,
                profile,
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

        // The versioned deployment plan is the sole v4 commit marker and is
        // atomically published last. Apply ignores incomplete temporary files.
        const fs::path planPath = stageRoot / "stage-plan.ini";
        if (!WriteFileBinaryAtomic(
                planPath,
                mq2webupdate::stageplan::Serialize(stageManifest)))
        {
            ++output.errorCount;
            output.status = "Stage Error";
            output.lastError =
                "Staging completed, but the validated deployment plan could not be committed.";
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
    void CompareWorkerMain(profilemodel::Profile profile)
    {
        CompareWorkerResult result;

        try
        {
            result = RunCompareWorker(profile);
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

    void StageWorkerMain(profilemodel::Profile profile)
    {
        CompareWorkerResult result;

        try
        {
            result = RunStageWorker(profile);
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

        profilemodel::Profile profileSnapshot;
        std::string profileError;

        if (!SnapshotMainDownloadProfile(profileSnapshot, profileError))
        {
            g_status = "Stage Error";
            g_lastError = profileError;
            WriteChatf("\ar[MQ2WebUpdate]\ax %s", g_lastError.c_str());
            return false;
        }

        g_compareProfileId = profileSnapshot.id;
        {
            auto& view = g_repositoryViews[g_compareProfileId];
            view = ManagedRepositoryView{};
            view.status = "Staging";
            view.lastChecked = MonitorTimestamp();
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

        // Created by: NeroMorte - Publish MQ2WebUpdate 2.0 staging lifecycle without changing live files.
        g_phase = "Staging";
        g_progress = 0;
        g_stageReady = false;
        g_restartRequired = false;

        g_compareRunning.store(true);

        try
        {
            g_compareThread =
                std::thread(StageWorkerMain, std::move(profileSnapshot));
        }
        catch (const std::exception& ex)
        {
            g_compareRunning.store(false);

            g_status = "Stage Error";
            g_lastError =
                std::string(
                    "Could not start stage worker: "
                ) + ex.what();

            // Created by: NeroMorte - Publish stage startup failure through the 2.0 API.
            g_phase = "Error";
            g_progress = 100;
            g_stageReady = false;
            g_restartRequired = false;

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

            // Created by: NeroMorte - Publish stage startup failure through the 2.0 API.
            g_phase = "Error";
            g_progress = 100;
            g_stageReady = false;
            g_restartRequired = false;

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

        profilemodel::Profile profileSnapshot;
        std::string profileError;

        if (!SnapshotMainDownloadProfile(profileSnapshot, profileError))
        {
            g_status = "Compare Error";
            g_lastError = profileError;
            WriteChatf("\ar[MQ2WebUpdate]\ax %s", g_lastError.c_str());
            return false;
        }

        g_compareProfileId = profileSnapshot.id;
        {
            auto& view = g_repositoryViews[g_compareProfileId];
            view = ManagedRepositoryView{};
            view.status = "Checking";
            view.lastChecked = MonitorTimestamp();
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

        // Created by: NeroMorte - Publish the MQ2WebUpdate 2.0 read-only plan lifecycle.
        g_phase = "Planning";
        g_progress = 0;

        // Created by: NeroMorte - A fresh comparison invalidates any previously published stage-ready state.
        g_stageReady = false;
        g_restartRequired = false;

        g_compareRunning.store(true);

        try
        {
            g_compareThread =
                std::thread(CompareWorkerMain, std::move(profileSnapshot));
        }
        catch (const std::exception& ex)
        {
            g_compareRunning.store(false);

            g_status = "Compare Error";
            g_lastError =
                std::string(
                    "Could not start compare worker: "
                ) + ex.what();

            // Created by: NeroMorte - Publish plan startup failure through the 2.0 API.
            g_phase = "Error";
            g_progress = 100;

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

            // Created by: NeroMorte - Publish plan startup failure through the 2.0 API.
            g_phase = "Error";
            g_progress = 100;

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

        // The result cannot be published until the worker has finished.
        // Reclaim it here so profile selection cannot race completed work.
        if (g_compareThread.joinable())
            g_compareThread.join();

        if (!g_compareProfileId.empty())
        {
            g_repositoryViews[g_compareProfileId] =
                BuildRepositoryView(result, MonitorTimestamp());
        }

        // We are back on MacroQuest's main thread here.
        g_remoteSha =
            std::move(result.remoteSha);

        g_remoteFiles =
            std::move(result.remoteFiles);

        g_fileResults =
            std::move(result.fileResults);

        g_repositoryTree =
            std::move(result.repositoryTree);

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

        // Created by: NeroMorte - Publish operation-aware MQ2WebUpdate 2.0 lifecycle state.
        if (result.operation == "stage")
        {
            const bool stagedFiles =
                result.stagedUpdateCount > 0 ||
                result.stagedMissingCount > 0;

            if (!result.success)
            {
                g_phase = "Error";
                g_stageReady = false;
            }
            else if (stagedFiles)
            {
                g_phase = "Staged";
                g_stageReady = true;
            }
            else
            {
                g_phase = "Ready";
                g_stageReady = false;
            }

            // Publish whether the committed plan contains a plugin or another
            // mapping explicitly marked as requiring a runtime restart.
            g_restartRequired =
                result.success && stagedFiles && result.restartRequired;
        }
        else
        {
            g_phase =
                result.success
                    ? "Ready"
                    : "Error";

            // A comparison is a plan, not a staged transaction.
            g_stageReady = false;
            g_restartRequired = false;
        }

        g_progress = 100;

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
            else if (file.status == "PROTECTED")
            {
                WriteChatf(
                    "\ao[MQ2WebUpdate]\ax PROTECTED %s",
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

    std::vector<std::string> TokenizeCommand(const std::string& command)
    {
        std::vector<std::string> tokens;
        std::istringstream input(command);
        std::string token;

        while (input >> token)
            tokens.push_back(std::move(token));

        return tokens;
    }

    std::string LowerAscii(std::string value)
    {
        std::transform(
            value.begin(), value.end(), value.begin(),
            [](unsigned char ch)
            {
                return static_cast<char>(std::tolower(ch));
            });
        return value;
    }

    fs::path GetProfileTransferPath()
    {
        const fs::path configuration = GetConfigurationPath();
        return configuration.empty()
            ? fs::path{}
            : configuration.parent_path() / "MQ2WebUpdate.profile-export.ini";
    }

    fs::path GetDiagnosticsPath()
    {
        const fs::path configuration = GetConfigurationPath();
        return configuration.empty()
            ? fs::path{}
            : configuration.parent_path() / "MQ2WebUpdate.diagnostics.txt";
    }

    bool ExportManagedProfiles(std::string& error)
    {
        const fs::path path = GetProfileTransferPath();
        if (path.empty())
        {
            error = "Could not resolve the fixed profile export path.";
            return false;
        }

        const std::string data =
            "; MQ2WebUpdate repository profiles and mappings\n"
            "; Credentials are intentionally never exported.\n" +
            profilemodel::SerializeProfiles(g_managedProfiles);

        if (!WriteFileBinaryAtomic(path, data))
        {
            error = "Could not atomically write the profile export.";
            return false;
        }

        error.clear();
        return true;
    }

    bool ImportManagedProfiles(std::string& error)
    {
        if (!CanEditManagedProfiles(error))
            return false;

        const fs::path path = GetProfileTransferPath();
        std::string data;
        if (path.empty() || !ReadFileBinary(path, data))
        {
            error = "Profile import file is missing from the fixed configuration path.";
            return false;
        }

        std::vector<profilemodel::Profile> candidate;
        if (!profilemodel::ParseProfileStore(data, candidate, error))
        {
            error = "Profile import rejected: " + error;
            return false;
        }

        return CommitManagedProfiles(std::move(candidate), error);
    }

    bool ExportDiagnostics(std::string& error)
    {
        const fs::path path = GetDiagnosticsPath();
        if (path.empty())
        {
            error = "Could not resolve the fixed diagnostics path.";
            return false;
        }

        std::ostringstream output;
        output << "MQ2WebUpdate diagnostics (credentials excluded)\n"
            << "Version=" << kWebUpdateVersion << "\n"
            << "ApiVersion=" << kWebUpdateApiVersion << "\n"
            << "Status=" << g_status << "\n"
            << "Phase=" << g_phase << "\n"
            << "StageReady=" << (g_stageReady ? 1 : 0) << "\n"
            << "RestartRequired=" << (g_restartRequired ? 1 : 0) << "\n"
            << "NetworkTimeoutSeconds=" << g_networkTimeoutSeconds << "\n"
            << "NetworkRetryCount=" << g_networkRetryCount << "\n"
            << "ProfileCount=" << g_managedProfiles.size() << "\n";

        for (const auto& profile : g_managedProfiles)
        {
            output << "Profile=" << profile.id << "|"
                << profilemodel::ProfileRoleName(profile.role) << "|"
                << profilemodel::SourceProviderName(profile.provider) << "|"
                << profile.owner << "/" << profile.repository << "@"
                << profile.reference << "|Enabled="
                << (profile.enabled ? 1 : 0) << "|Private="
                << (profile.privateRepository ? 1 : 0);

            const auto view = g_repositoryViews.find(profile.id);
            if (view != g_repositoryViews.end())
            {
                output << "|PlanStatus=" << view->second.status
                    << "|PlanSHA=" << view->second.remoteSha
                    << "|Files=" << view->second.fileResults.size()
                    << "|Same=" << view->second.sameCount
                    << "|Update=" << view->second.updateCount
                    << "|New=" << view->second.missingCount
                    << "|Protected=" << view->second.protectedCount
                    << "|Errors=" << view->second.errorCount;
            }
            output << "\n";
        }

        if (!g_lastError.empty()) output << "LastError=" << g_lastError << "\n";
        if (!g_profileStoreError.empty())
            output << "ProfileStoreError=" << g_profileStoreError << "\n";

        if (!WriteFileBinaryAtomic(path, output.str()))
        {
            error = "Could not atomically write sanitized diagnostics.";
            return false;
        }

        error.clear();
        return true;
    }
}

void WebUpdateCmd(
    PSPAWNINFO pChar,
    PCHAR szLine)
{
    const std::string rawCommand = szLine ? szLine : "";
    const std::vector<std::string> rawTokens =
        TokenizeCommand(rawCommand);

    if (!rawTokens.empty())
    {
        const std::string group = LowerAscii(rawTokens[0]);
        const std::string action = rawTokens.size() > 1
            ? LowerAscii(rawTokens[1])
            : std::string();
        std::string editError;
        bool handled = false;
        bool success = false;
        std::string successMessage = "Configuration saved.";

        if (group == "profiles" && action == "create" && rawTokens.size() == 3)
        {
            handled = true;
            success = CreateManagedProfile(rawTokens[2], editError);
        }
        else if (group == "profiles" && action == "export" && rawTokens.size() == 2)
        {
            handled = true;
            success = ExportManagedProfiles(editError);
            successMessage = "Profiles exported without credentials to " +
                GetProfileTransferPath().string();
        }
        else if (group == "profiles" && action == "import" && rawTokens.size() == 2)
        {
            handled = true;
            success = ImportManagedProfiles(editError);
            successMessage = "Validated profile import published atomically.";
        }
        else if (group == "profiles" && action == "delete" && rawTokens.size() == 3)
        {
            handled = true;
            success = DeleteManagedProfile(rawTokens[2], editError);
        }
        else if (group == "profiles" && action == "duplicate" && rawTokens.size() == 4)
        {
            handled = true;
            success = DuplicateManagedProfile(
                rawTokens[2], rawTokens[3], editError);
        }
        else if (group == "profiles" && action == "test" && rawTokens.size() == 3)
        {
            handled = true;
            success = StartManagedMonitorCheck(rawTokens[2]);
            successMessage = "Read-only repository comparison started.";
            if (!success) editError =
                "Repository test could not start; verify the profile is enabled and no monitor check is running.";
        }
        else if (group == "profiles" && action == "set" && rawTokens.size() == 5)
        {
            handled = true;
            std::string decoded;

            if (!profilemodel::UnescapeValue(rawTokens[4], decoded))
                editError = "Profile value encoding is invalid.";
            else
                success = SetManagedProfileField(
                    rawTokens[2], LowerAscii(rawTokens[3]), decoded, editError);
        }
        else if (group == "mappings" && action == "create" && rawTokens.size() == 4)
        {
            handled = true;
            success = CreateManagedMapping(rawTokens[2], rawTokens[3], editError);
        }
        else if (group == "mappings" && action == "delete" && rawTokens.size() == 4)
        {
            handled = true;
            success = DeleteManagedMapping(rawTokens[2], rawTokens[3], editError);
        }
        else if (group == "mappings" && action == "set" && rawTokens.size() == 6)
        {
            handled = true;
            std::string decoded;

            if (!profilemodel::UnescapeValue(rawTokens[5], decoded))
                editError = "Mapping value encoding is invalid.";
            else
                success = SetManagedMappingField(
                    rawTokens[2], rawTokens[3], LowerAscii(rawTokens[4]),
                    decoded, editError);
        }
        else if (group == "mappings" && action == "exclude" && rawTokens.size() == 5)
        {
            handled = true;
            std::string decoded;
            if (!profilemodel::UnescapeValue(rawTokens[4], decoded))
                editError = "Excluded path encoding is invalid.";
            else
                success = AddManagedMappingExclusion(
                    rawTokens[2], rawTokens[3], decoded, editError);
        }
        else if (group == "mappings" && action == "selection" && rawTokens.size() == 6)
        {
            handled = true;
            std::string decoded;
            bool selected = false;
            if (!profilemodel::UnescapeValue(rawTokens[4], decoded))
                editError = "Selection path encoding is invalid.";
            else if (!ParseEnabledValue(rawTokens[5], selected))
                editError = "Selection state must be on or off.";
            else
                success = SetManagedMappingSelection(
                    rawTokens[2], rawTokens[3], decoded, selected, editError);
        }
        else if (group == "mappings" && action == "folderselection" && rawTokens.size() == 6)
        {
            handled = true;
            std::string decoded;
            bool selected = false;
            if (!profilemodel::UnescapeValue(rawTokens[4], decoded))
                editError = "Folder selection encoding is invalid.";
            else if (!ParseEnabledValue(rawTokens[5], selected))
                editError = "Folder selection state must be on or off.";
            else
                success = SetManagedMappingFolderSelection(
                    rawTokens[2], rawTokens[3], decoded, selected, editError);
        }
#ifdef _WIN32
        else if (group == "credential" && action == "set" && rawTokens.size() == 4)
        {
            handled = true;
            std::string token;

            if (!profilemodel::UnescapeValue(rawTokens[3], token))
                editError = "Credential encoding is invalid.";
            else
                success = mq2webupdate::credentials::StoreGitHubToken(
                    rawTokens[2], token, editError);

            mq2webupdate::credentials::SecureClear(token);
        }
        else if (group == "credential" && action == "delete" && rawTokens.size() == 3)
        {
            handled = true;
            success = mq2webupdate::credentials::DeleteGitHubToken(
                rawTokens[2], editError);
        }
#endif

        if (handled)
        {
            if (success)
            {
                WriteChatf(
                    "\ag[MQ2WebUpdate]\ax %s",
                    successMessage.c_str()
                );
            }
            else
            {
                WriteChatf(
                    "\ar[MQ2WebUpdate]\ax Configuration rejected: %s",
                    editError.c_str()
                );
            }
            return;
        }

        if (group == "credential")
        {
            WriteChatf(
                "\ar[MQ2WebUpdate]\ax Credential command rejected. Token values are never echoed."
            );
            return;
        }
    }

    std::string command =
        NormalizeCommand(
            szLine ? szLine : ""
        );

    if (command.empty() ||
        command == "help" ||
        command == "?")
    {
        ShowHelp();
        return;
    }

    if (command == "profile")
    {
        WriteChatf("\ay[MQ2WebUpdate]\ax Saved update profiles:");
        for (const auto& profile : g_managedProfiles)
        {
            const bool active = profile.role == profilemodel::ProfileRole::MainDownload;
            WriteChatf(
                active
                    ? "\ag[MQ2WebUpdate]\ax * %s - %s/%s @ %s"
                    : "\at[MQ2WebUpdate]\ax   %s - %s/%s @ %s",
                profile.id.c_str(), profile.owner.c_str(),
                profile.repository.c_str(), profile.reference.c_str()
            );
        }

        return;
    }

    constexpr const char* profilePrefix = "profile ";

    if (command.rfind(profilePrefix, 0) == 0)
    {
        std::string requested = szLine ? szLine : "";
        requested.erase(0, requested.find_first_not_of(" \t\r\n"));
        requested = requested.substr(std::char_traits<char>::length(profilePrefix));
        requested.erase(requested.find_last_not_of(" \t\r\n") + 1);

        std::string error;
        if (!SetManagedProfileField(requested, "role", "main", error))
        {
            WriteChatf(
                "\ar[MQ2WebUpdate]\ax Profile change rejected: %s",
                error.c_str()
            );

            return;
        }

        const auto* profile = GetManagedMainProfile();
        if (profile)
            WriteChatf("\ag[MQ2WebUpdate]\ax Main Download saved: %s (%s/%s @ %s)",
                profile->id.c_str(), profile->owner.c_str(),
                profile->repository.c_str(), profile->reference.c_str());

        return;
    }

    if (command == "config show")
    {
        ShowStatus();
        WriteChatf(
            "\ay[MQ2WebUpdate]\ax Settings file: %s",
            g_configurationPath.c_str()
        );
        return;
    }

    if (command == "config reset")
    {
        if (!ResetConfiguration())
        {
            WriteChatf(
                "\ar[MQ2WebUpdate]\ax Configuration reset rejected: %s",
                g_lastError.c_str()
            );
            return;
        }

        WriteChatf(
            "\ag[MQ2WebUpdate]\ax Configuration reset to safe defaults."
        );
        return;
    }

    if (command == "diagnostics export")
    {
        std::string error;
        if (!ExportDiagnostics(error))
        {
            WriteChatf("\ar[MQ2WebUpdate]\ax Diagnostics export failed: %s", error.c_str());
            return;
        }
        WriteChatf(
            "\ag[MQ2WebUpdate]\ax Sanitized diagnostics exported: %s",
            GetDiagnosticsPath().string().c_str());
        return;
    }

    constexpr const char* settingPrefix = "setting ";

    if (command.rfind(settingPrefix, 0) == 0)
    {
        const std::string arguments =
            command.substr(std::char_traits<char>::length(settingPrefix));
        const auto separator = arguments.find(' ');

        if (separator == std::string::npos)
        {
            WriteChatf(
                "\ar[MQ2WebUpdate]\ax Usage: /webupdate setting <checkonload|monitoronload|upstreamonload|interval|timeout|retries> <value>"
            );
            return;
        }

        const std::string key = arguments.substr(0, separator);
        const std::string value = arguments.substr(separator + 1);

        if (!SaveAutomationSetting(key, value))
        {
            WriteChatf(
                "\ar[MQ2WebUpdate]\ax Setting rejected: %s",
                g_lastError.c_str()
            );
            return;
        }

        WriteChatf(
            "\ag[MQ2WebUpdate]\ax Setting saved: %s=%s",
            key.c_str(),
            value.c_str()
        );
        return;
    }

    if (command == "check")
    {
        WriteChatf(
            "\ag[MQ2WebUpdate]\ax Checking GitHub for latest commit..."
        );

        StartAsyncCompare();
        return;
    }

    if (command == "upstream")
    {
        StartManagedMonitorCheck();
        return;
    }

    if (command == "upstreamsilent")
    {
        StartManagedMonitorCheck();
        return;
    }

    if (command == "monitors")
    {
        if (StartManagedMonitorCheck())
            WriteChatf("\ag[MQ2WebUpdate]\ax Monitor Only repository checks started.");
        else
            WriteChatf("\ay[MQ2WebUpdate]\ax Monitor checks are already running or could not start.");
        return;
    }

    if (command == "scan")
    {
        WriteChatf(
            "\ag[MQ2WebUpdate]\ax Scanning GitHub repository..."
        );

        StartAsyncCompare();
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

    if (command.rfind("dll prepare ", 0) == 0)
    {
        std::string error;
        std::string mappingId = szLine ? szLine : "";
        mappingId.erase(0, mappingId.find_first_not_of(" \t\r\n"));
        mappingId = mappingId.substr(12);
        mappingId.erase(mappingId.find_last_not_of(" \t\r\n") + 1);
        if (PrepareDllHandoff(mappingId, error))
        {
            g_lastError.clear();
            WriteChatf("\ag[MQ2WebUpdate]\ax DLL handoff ready; start the independent Lua coordinator.");
        }
        else
        {
            g_lastError = error;
            WriteChatf("\ar[MQ2WebUpdate]\ax DLL handoff rejected: %s", error.c_str());
        }
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
        if (g_fileResults.empty())
        {
            WriteChatf("\ay[MQ2WebUpdate]\ax Run /webupdate compare first to populate the mapped file plan.");
        }
        else
        {
            for (const auto& file : g_fileResults)
                WriteChatf("\at[MQ2WebUpdate]\ax %s: %s %s",
                    file.destinationPath.c_str(), file.status.c_str(),
                    file.protection.c_str());
        }
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
    PublishAsyncUpstreamResult();
    PublishAsyncCompareResult();
    PublishManagedMonitorResults();

    if (!g_monitorRunning.load())
    {
        const auto now = std::chrono::steady_clock::now();
        std::string dueProfileId;
        for (const auto& profile : g_managedProfiles)
        {
            if (!profile.enabled ||
                profile.role != profilemodel::ProfileRole::MonitorOnly ||
                profile.monitorIntervalMinutes == 0)
                continue;
            const auto found = g_monitorNextCheck.find(profile.id);
            if (found != g_monitorNextCheck.end() && found->second <= now)
            {
                dueProfileId = profile.id;
                break;
            }
        }
        if (!dueProfileId.empty()) StartManagedMonitorCheck(dueProfileId);
    }

    if (g_autoCheckIntervalMinutes > 0 &&
        std::chrono::steady_clock::now() >= g_nextAutomaticCheck)
    {
        g_nextAutomaticCheck =
            std::chrono::steady_clock::now() +
            std::chrono::minutes(g_autoCheckIntervalMinutes);

        if (!g_compareRunning.load() &&
            !g_upstreamRunning.load() &&
            !g_monitorRunning.load() &&
            !g_stageReady &&
            !HasActiveTransactionRecord())
        {
            WriteChatf(
                "\ay[MQ2WebUpdate]\ax Scheduled read-only update check started."
            );
            StartAsyncCompare();
            StartManagedMonitorCheck();
        }
    }
}
PLUGIN_API void InitializePlugin()
{
    // Load the trusted source selection before recovery validates any
    // persisted transaction identity.
    LoadConfiguration();

    // Load the configured repositories and deployment mappings before
    // starting any checks, staging, or transaction recovery.
    if (!LoadManagedProfiles())
    {
        WriteChatf(
            "\ar[MQ2WebUpdate]\ax Profile store rejected: %s",
            g_profileStoreError.c_str()
        );
    }

    const auto monitorNow = std::chrono::steady_clock::now();
    for (const auto& profile : g_managedProfiles)
    {
        if (!profile.enabled ||
            profile.role != profilemodel::ProfileRole::MonitorOnly)
            continue;
        g_monitorNextCheck[profile.id] = profile.monitorOnStartup
            ? monitorNow
            : monitorNow + std::chrono::minutes(
                profile.monitorIntervalMinutes > 0
                    ? profile.monitorIntervalMinutes : 1);
    }

    pWebUpdateFileType =
        new MQ2WebUpdateFileType();

    pWebUpdateTreeFileType =
        new MQ2WebUpdateTreeFileType();

    // Created by: NeroMorte - MQ2WebUpdate 2.0 indexed profile datatype.
    pWebUpdateProfileType =
        new MQ2WebUpdateProfileType();

    pWebUpdateMappingType =
        new MQ2WebUpdateMappingType();

    pWebUpdateManagedProfileType =
        new MQ2WebUpdateManagedProfileType();

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

    // Created by: NeroMorte - MQ2WebUpdate 3.0 startup identity.
    WriteChatf(
        "\ag[MQ2WebUpdate v%s]\ax Loaded - Created by NeroMorte",
        kWebUpdateVersion
    );

    WriteChatf(
        "\ay[MQ2WebUpdate]\ax Safe transactional updater backend for MacroQuest deployments. Use /webupdate help."
    );

    // Created by: NeroMorte - Automatically resume only fully validated
    // interrupted updater transactions; unsafe evidence remains untouched.
    RecoverInterruptedApplyTransactionAtStartup();

    const bool startupMonitorRequested = g_autoMonitorOnLoad || std::any_of(
        g_managedProfiles.begin(), g_managedProfiles.end(),
        [](const profilemodel::Profile& profile)
        {
            return profile.enabled &&
                profile.role == profilemodel::ProfileRole::MonitorOnly &&
                profile.monitorOnStartup;
        });
    if (startupMonitorRequested)
        StartManagedMonitorCheck();

    if (g_autoCheckOnLoad && !HasActiveTransactionRecord())
    {
        WriteChatf(
            "\ay[MQ2WebUpdate]\ax Automatic startup update check enabled."
        );
        StartAsyncCompare();
    }

    if (g_autoUpstreamOnLoad)
    {
        WriteChatf(
            "\ay[MQ2WebUpdate]\ax Automatic startup upstream check enabled."
        );
        StartManagedMonitorCheck();
    }
}

PLUGIN_API void ShutdownPlugin()
{
    if (g_monitorThread.joinable())
    {
        g_monitorThread.join();
    }

    if (g_upstreamThread.joinable())
    {
        g_upstreamThread.join();
    }

    // Never allow the plugin DLL to unload while its background
    // compare worker is still executing code from this module.
    if (g_compareThread.joinable())
    {
        g_compareThread.join();
    }

    g_compareRunning.store(false);
    g_monitorRunning.store(false);

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

    // Created by: NeroMorte - MQ2WebUpdate 2.0 indexed profile datatype.
    delete pWebUpdateProfileType;
    pWebUpdateProfileType = nullptr;

    delete pWebUpdateManagedProfileType;
    pWebUpdateManagedProfileType = nullptr;

    delete pWebUpdateMappingType;
    pWebUpdateMappingType = nullptr;

    delete pWebUpdateFileType;
    pWebUpdateFileType = nullptr;

    delete pWebUpdateTreeFileType;
    pWebUpdateTreeFileType = nullptr;
    RemoveCommand(
        "/webupdate"
    );

    DebugSpewAlways(
        "Shutting down MQ2WebUpdate"
    );
}
