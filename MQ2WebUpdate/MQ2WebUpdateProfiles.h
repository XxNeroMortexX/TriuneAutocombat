#pragma once

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <filesystem>
#include <optional>
#include <set>
#include <string>
#include <vector>

namespace mq2webupdate::profiles
{
    namespace fs = std::filesystem;

    enum class DestinationRoot
    {
        Lua,
        Macros,
        Plugins,
        Config,
        Resources,
        // Edited By: NeroMorte - standalone payloads beside MacroQuest.exe.
        MQ
    };

    enum class ProfileRole
    {
        MainDownload,
        MonitorOnly,
        Disabled
    };

    // Provider is persisted even while GitHub is the only enabled v4
    // implementation.  Future providers plug into the acquisition layer;
    // the validated plan, stage, apply, rollback, and recovery layers stay
    // provider-independent.
    enum class SourceProvider
    {
        GitHub
    };

    struct Mapping
    {
        std::string id;
        std::string name;
        bool enabled = true;
        bool recursive = true;
        bool required = true;
        bool restartRequired = false;
        std::string remotePath;
        DestinationRoot destinationRoot = DestinationRoot::Lua;
        std::string destinationPath;
        std::vector<std::string> includePatterns;
        std::vector<std::string> excludePatterns;
        std::uint64_t maximumFileBytes = 64ull * 1024ull * 1024ull;
    };

    struct Profile
    {
        std::string id;
        std::string name;
        bool enabled = true;
        ProfileRole role = ProfileRole::MonitorOnly;
        SourceProvider provider = SourceProvider::GitHub;
        bool privateRepository = false;
        std::string owner;
        std::string repository;
        std::string reference = "main";
        std::string channel = "stable";
        bool monitorOnStartup = false;
        std::uint32_t monitorIntervalMinutes = 0;
        bool notificationsEnabled = true;
        std::string acknowledgedSha;
        std::vector<Mapping> mappings;
    };

    struct ValidationError
    {
        std::string field;
        std::string message;
    };

    struct ValidationResult
    {
        std::vector<ValidationError> errors;

        bool IsValid() const
        {
            return errors.empty();
        }

        void Add(
            std::string field,
            std::string message)
        {
            errors.push_back({ std::move(field), std::move(message) });
        }
    };

    inline bool IsAsciiIdentifier(
        const std::string& value,
        std::size_t maximumLength = 64)
    {
        if (value.empty() || value.size() > maximumLength)
            return false;

        return std::all_of(
            value.begin(),
            value.end(),
            [](unsigned char ch)
            {
                return std::isalnum(ch) || ch == '-' || ch == '_';
            });
    }

    inline bool IsGitHubComponent(
        const std::string& value,
        std::size_t maximumLength = 100)
    {
        if (value.empty() || value.size() > maximumLength)
            return false;

        if (value.front() == '.' || value.back() == '.' ||
            value.front() == '-' || value.back() == '-')
        {
            return false;
        }

        return std::all_of(
            value.begin(),
            value.end(),
            [](unsigned char ch)
            {
                return std::isalnum(ch) || ch == '-' || ch == '_' || ch == '.';
            });
    }

    inline bool IsSafeRelativePath(const std::string& value)
    {
        if (value.empty())
            return true;

        if (value.find('\0') != std::string::npos ||
            value.find(':') != std::string::npos ||
            value.rfind("//", 0) == 0 ||
            value.rfind("\\\\", 0) == 0)
        {
            return false;
        }

        std::string normalized = value;
        std::replace(normalized.begin(), normalized.end(), '\\', '/');

        const fs::path path(normalized);

        if (path.is_absolute() || path.has_root_directory() ||
            path.has_root_name())
        {
            return false;
        }

        for (const auto& component : path)
        {
            if (component == ".." || component == ".")
                return false;
        }

        return true;
    }

    inline const char* DestinationRootName(DestinationRoot root)
    {
        switch (root)
        {
        case DestinationRoot::Lua: return "lua";
        case DestinationRoot::Macros: return "macros";
        case DestinationRoot::Plugins: return "plugins";
        case DestinationRoot::Config: return "config";
        case DestinationRoot::Resources: return "resources";
        // Edited By: NeroMorte - name the top-level runtime root.
        case DestinationRoot::MQ: return "mq";
        }

        return "unknown";
    }

    inline const char* ProfileRoleName(ProfileRole role)
    {
        switch (role)
        {
        case ProfileRole::MainDownload: return "main";
        case ProfileRole::MonitorOnly: return "monitor";
        case ProfileRole::Disabled: return "disabled";
        }

        return "disabled";
    }

    inline const char* SourceProviderName(SourceProvider provider)
    {
        switch (provider)
        {
        case SourceProvider::GitHub: return "github";
        }

        return "unknown";
    }

    inline std::optional<SourceProvider> ParseSourceProvider(
        const std::string& value)
    {
        if (value == "github") return SourceProvider::GitHub;
        return std::nullopt;
    }

    inline std::optional<ProfileRole> ParseProfileRole(
        const std::string& value)
    {
        if (value == "main") return ProfileRole::MainDownload;
        if (value == "monitor") return ProfileRole::MonitorOnly;
        if (value == "disabled") return ProfileRole::Disabled;
        return std::nullopt;
    }

    inline std::optional<DestinationRoot> ParseDestinationRoot(
        const std::string& value)
    {
        if (value == "lua") return DestinationRoot::Lua;
        if (value == "macros") return DestinationRoot::Macros;
        if (value == "plugins") return DestinationRoot::Plugins;
        if (value == "config") return DestinationRoot::Config;
        if (value == "resources") return DestinationRoot::Resources;
        // Edited By: NeroMorte - accept the explicit runtime-root mapping.
        if (value == "mq") return DestinationRoot::MQ;
        return std::nullopt;
    }

    inline fs::path ResolveDestinationRoot(
        const fs::path& runtimeRoot,
        DestinationRoot root)
    {
        switch (root)
        {
        case DestinationRoot::Lua: return runtimeRoot / "lua";
        case DestinationRoot::Macros: return runtimeRoot / "macros";
        case DestinationRoot::Plugins: return runtimeRoot / "plugins";
        case DestinationRoot::Config: return runtimeRoot / "config";
        case DestinationRoot::Resources: return runtimeRoot / "resources";
        // Edited By: NeroMorte - preserve the actual MQ installation path.
        case DestinationRoot::MQ: return runtimeRoot;
        }

        return {};
    }

    // Created By: NeroMorte - root payloads are flat files, so they cannot alias
    // Lua/plugin/config mappings or internal updater transaction folders.
    inline bool IsSafeDeploymentPath(DestinationRoot root, const std::string& path)
    {
        return !path.empty() && IsSafeRelativePath(path) &&
            (root != DestinationRoot::MQ || path.find_first_of("/\\") == std::string::npos);
    }

    inline ValidationResult ValidateMapping(const Mapping& mapping)
    {
        ValidationResult result;

        if (!IsAsciiIdentifier(mapping.id))
            result.Add("Mapping.ID", "Use 1-64 letters, numbers, hyphens, or underscores.");

        if (mapping.name.empty() || mapping.name.size() > 128)
            result.Add("Mapping.Name", "Name must contain 1-128 characters.");

        if (mapping.remotePath.empty() || !IsSafeRelativePath(mapping.remotePath))
            result.Add("Mapping.RemotePath", "Remote path must be a safe repository-relative path.");

        if (!IsSafeRelativePath(mapping.destinationPath))
            result.Add("Mapping.DestinationPath", "Destination must remain relative to its allowed root.");

        // Edited By: NeroMorte - reserve mq for direct runtime files only.
        if (mapping.destinationRoot == DestinationRoot::MQ &&
            (!mapping.destinationPath.empty() || mapping.recursive))
        {
            result.Add("Mapping.DestinationRoot", "MQ-root mappings must be nonrecursive with an empty destination path.");
        }

        if (mapping.maximumFileBytes == 0 ||
            mapping.maximumFileBytes > 1024ull * 1024ull * 1024ull)
        {
            result.Add("Mapping.MaximumFileBytes", "Limit must be between 1 byte and 1 GiB.");
        }

        return result;
    }

    inline ValidationResult ValidateProfile(const Profile& profile)
    {
        ValidationResult result;

        if (!IsAsciiIdentifier(profile.id))
            result.Add("Profile.ID", "Use 1-64 letters, numbers, hyphens, or underscores.");

        if (profile.name.empty() || profile.name.size() > 128)
            result.Add("Profile.Name", "Name must contain 1-128 characters.");

        if (!IsGitHubComponent(profile.owner))
            result.Add("Profile.Owner", "GitHub owner is invalid.");

        if (!IsGitHubComponent(profile.repository))
            result.Add("Profile.Repository", "GitHub repository is invalid.");

        if (profile.reference.empty() || profile.reference.size() > 255 ||
            profile.reference.find("..") != std::string::npos ||
            profile.reference.find('\\') != std::string::npos ||
            profile.reference.front() == '/' || profile.reference.back() == '/')
        {
            result.Add("Profile.Reference", "Branch, tag, or commit reference is invalid.");
        }

        if (profile.mappings.empty())
            result.Add("Profile.Mappings", "At least one mapping is required.");

        if (profile.monitorIntervalMinutes > 10080)
            result.Add("Profile.MonitorIntervalMinutes", "Monitoring interval cannot exceed 7 days.");

        if (!profile.acknowledgedSha.empty() &&
            (profile.acknowledgedSha.size() != 40 ||
             !std::all_of(profile.acknowledgedSha.begin(), profile.acknowledgedSha.end(),
                [](unsigned char ch) { return std::isxdigit(ch) != 0; })))
        {
            result.Add("Profile.AcknowledgedSHA", "Acknowledged SHA must be empty or a 40-character Git commit SHA.");
        }

        std::set<std::string> mappingIds;

        for (std::size_t i = 0; i < profile.mappings.size(); ++i)
        {
            const Mapping& mapping = profile.mappings[i];
            ValidationResult mappingResult = ValidateMapping(mapping);

            for (auto& error : mappingResult.errors)
            {
                error.field = "Mapping[" + std::to_string(i) + "]." + error.field;
                result.errors.push_back(std::move(error));
            }

            if (!mappingIds.insert(mapping.id).second)
                result.Add("Profile.Mappings", "Mapping IDs must be unique within a profile.");
        }

        return result;
    }

    inline ValidationResult ValidateProfileSet(
        const std::vector<Profile>& profiles)
    {
        ValidationResult result;
        std::set<std::string> ids;
        std::size_t mainCount = 0;

        if (profiles.empty())
            result.Add("Profiles", "At least one repository profile is required.");

        for (std::size_t i = 0; i < profiles.size(); ++i)
        {
            const Profile& profile = profiles[i];
            ValidationResult profileResult = ValidateProfile(profile);

            for (auto& error : profileResult.errors)
            {
                error.field = "Profile[" + std::to_string(i) + "]." + error.field;
                result.errors.push_back(std::move(error));
            }

            if (!ids.insert(profile.id).second)
                result.Add("Profiles", "Profile IDs must be unique.");

            if (profile.enabled && profile.role == ProfileRole::MainDownload)
                ++mainCount;
        }

        if (mainCount != 1)
        {
            result.Add(
                "Profiles.MainDownload",
                "Exactly one enabled Main Download repository is required.");
        }

        return result;
    }
}
