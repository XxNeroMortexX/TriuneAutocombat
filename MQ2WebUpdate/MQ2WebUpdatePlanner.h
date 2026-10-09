#pragma once

#include "MQ2WebUpdateProfiles.h"

#include <map>

namespace mq2webupdate::planner
{
    struct RemoteTreeFile
    {
        std::string repositoryPath;
        std::uint64_t size = 0;
        std::string gitObjectSha;
    };

    struct PlanItem
    {
        std::string profileId;
        std::string mappingId;
        std::string repositoryPath;
        std::string stageRelativePath;
        mq2webupdate::profiles::DestinationRoot destinationRoot =
            mq2webupdate::profiles::DestinationRoot::Lua;
        std::string destinationRelativePath;
        std::uint64_t expectedSize = 0;
        std::string gitObjectSha;
        bool restartRequired = false;
    };

    struct PlanResult
    {
        std::vector<PlanItem> items;
        std::vector<std::string> errors;

        bool IsValid() const
        {
            return errors.empty();
        }
    };

    struct BrowserEntry
    {
        std::string mappingId;
        std::string repositoryPath;
        std::string mappingRelativePath;
        std::uint64_t size = 0;
        bool selected = false;
    };

    inline std::string NormalizeRepositoryPath(std::string value)
    {
        std::replace(value.begin(), value.end(), '\\', '/');

        while (!value.empty() && value.front() == '/')
            value.erase(value.begin());

        while (!value.empty() && value.back() == '/')
            value.pop_back();

        return value;
    }

    inline bool GlobMatch(
        const std::string& pattern,
        const std::string& value,
        std::size_t patternIndex = 0,
        std::size_t valueIndex = 0)
    {
        while (patternIndex < pattern.size())
        {
            if (pattern[patternIndex] == '*')
            {
                const bool doubleStar =
                    patternIndex + 1 < pattern.size() &&
                    pattern[patternIndex + 1] == '*';

                patternIndex += doubleStar ? 2 : 1;

                if (patternIndex == pattern.size())
                {
                    return doubleStar ||
                        value.find('/', valueIndex) == std::string::npos;
                }

                for (std::size_t i = valueIndex; i <= value.size(); ++i)
                {
                    if (!doubleStar && i > valueIndex && value[i - 1] == '/')
                        break;

                    if (GlobMatch(pattern, value, patternIndex, i))
                        return true;
                }

                return false;
            }

            if (valueIndex >= value.size())
                return false;

            if (pattern[patternIndex] == '?')
            {
                if (value[valueIndex] == '/')
                    return false;
            }
            else if (pattern[patternIndex] != value[valueIndex])
            {
                return false;
            }

            ++patternIndex;
            ++valueIndex;
        }

        return valueIndex == value.size();
    }

    inline bool MatchesPatterns(
        const std::string& relativePath,
        const std::vector<std::string>& includes,
        const std::vector<std::string>& excludes)
    {
        bool included = includes.empty();

        for (const auto& pattern : includes)
        {
            if (pattern == "**" || GlobMatch(pattern, relativePath))
            {
                included = true;
                break;
            }
        }

        if (!included)
            return false;

        for (const auto& pattern : excludes)
        {
            if (pattern == "**" || GlobMatch(pattern, relativePath))
                return false;
        }

        return true;
    }

    enum class PlanPurpose
    {
        ReadOnlyComparison,
        Install
    };

    inline PlanResult BuildPlan(
        const mq2webupdate::profiles::Profile& profile,
        const std::vector<RemoteTreeFile>& remoteFiles,
        PlanPurpose purpose)
    {
        PlanResult result;
        const auto validation =
            mq2webupdate::profiles::ValidateProfile(profile);

        if (!validation.IsValid())
        {
            for (const auto& error : validation.errors)
                result.errors.push_back(error.field + ": " + error.message);

            return result;
        }

        if (!profile.enabled)
        {
            result.errors.push_back("The selected profile is disabled.");
            return result;
        }

        if (purpose == PlanPurpose::Install &&
            profile.role !=
            mq2webupdate::profiles::ProfileRole::MainDownload)
        {
            result.errors.push_back(
                "Only the Main Download repository may produce an install plan.");
            return result;
        }

        std::map<std::string, std::string> destinations;

        for (const auto& mapping : profile.mappings)
        {
            if (!mapping.enabled)
                continue;

            const std::string remoteRoot =
                NormalizeRepositoryPath(mapping.remotePath);
            std::size_t matchedCount = 0;

            for (const auto& remote : remoteFiles)
            {
                const std::string repositoryPath =
                    NormalizeRepositoryPath(remote.repositoryPath);
                std::string relativePath;

                if (repositoryPath == remoteRoot)
                {
                    const std::size_t slash = repositoryPath.find_last_of('/');
                    relativePath = slash == std::string::npos
                        ? repositoryPath
                        : repositoryPath.substr(slash + 1);
                }
                else
                {
                    const std::string prefix = remoteRoot + "/";

                    if (repositoryPath.rfind(prefix, 0) != 0)
                        continue;

                    relativePath = repositoryPath.substr(prefix.size());
                }

                if (!mapping.recursive &&
                    relativePath.find('/') != std::string::npos)
                {
                    continue;
                }

                if (!mq2webupdate::profiles::IsSafeRelativePath(relativePath) ||
                    !MatchesPatterns(
                        relativePath,
                        mapping.includePatterns,
                        mapping.excludePatterns))
                {
                    continue;
                }

                if (remote.size > mapping.maximumFileBytes)
                {
                    result.errors.push_back(
                        repositoryPath + " exceeds mapping " +
                        mapping.id + " maximum file size.");
                    continue;
                }

                const std::filesystem::path destinationRelative =
                    std::filesystem::path(mapping.destinationPath) /
                    std::filesystem::path(relativePath);

                // Edited By: NeroMorte - runtime-root payloads stay flat and within their root.
                if (!mq2webupdate::profiles::IsSafeDeploymentPath(
                        mapping.destinationRoot, destinationRelative.generic_string()))
                {
                    result.errors.push_back(
                        repositoryPath + " produced an unsafe destination.");
                    continue;
                }

                const std::string destinationKey =
                    std::string(mq2webupdate::profiles::DestinationRootName(
                        mapping.destinationRoot)) + "/" +
                    destinationRelative.generic_string();

                const auto collision = destinations.find(destinationKey);

                if (collision != destinations.end())
                {
                    result.errors.push_back(
                        "Destination collision: " + repositoryPath +
                        " and " + collision->second + " both map to " +
                        destinationKey + ".");
                    continue;
                }

                destinations.emplace(destinationKey, repositoryPath);

                PlanItem item;
                item.profileId = profile.id;
                item.mappingId = mapping.id;
                item.repositoryPath = repositoryPath;
                item.stageRelativePath =
                    mapping.id + "/" + relativePath;
                item.destinationRoot = mapping.destinationRoot;
                item.destinationRelativePath =
                    destinationRelative.generic_string();
                item.expectedSize = remote.size;
                item.gitObjectSha = remote.gitObjectSha;
                item.restartRequired =
                    mapping.restartRequired ||
                    mapping.destinationRoot ==
                        mq2webupdate::profiles::DestinationRoot::Plugins;
                result.items.push_back(std::move(item));
                ++matchedCount;
            }

            if (mapping.required && matchedCount == 0)
            {
                result.errors.push_back(
                    "Required mapping " + mapping.id +
                    " selected no repository files.");
            }
        }

        std::sort(
            result.items.begin(),
            result.items.end(),
            [](const PlanItem& left, const PlanItem& right)
            {
                if (left.mappingId != right.mappingId)
                    return left.mappingId < right.mappingId;

                return left.repositoryPath < right.repositoryPath;
            });

        return result;
    }

    inline std::vector<BrowserEntry> BuildBrowserEntries(
        const mq2webupdate::profiles::Profile& profile,
        const std::vector<RemoteTreeFile>& remoteFiles)
    {
        std::vector<BrowserEntry> entries;

        for (const auto& mapping : profile.mappings)
        {
            if (!mapping.enabled) continue;
            const std::string remoteRoot =
                NormalizeRepositoryPath(mapping.remotePath);

            for (const auto& remote : remoteFiles)
            {
                const std::string repositoryPath =
                    NormalizeRepositoryPath(remote.repositoryPath);
                std::string relativePath;
                if (repositoryPath == remoteRoot)
                {
                    const auto slash = repositoryPath.find_last_of('/');
                    relativePath = slash == std::string::npos
                        ? repositoryPath : repositoryPath.substr(slash + 1);
                }
                else
                {
                    const std::string prefix = remoteRoot + "/";
                    if (repositoryPath.rfind(prefix, 0) != 0) continue;
                    relativePath = repositoryPath.substr(prefix.size());
                }

                if (!mapping.recursive && relativePath.find('/') != std::string::npos)
                    continue;
                if (relativePath.empty() ||
                    !mq2webupdate::profiles::IsSafeRelativePath(relativePath))
                    continue;

                BrowserEntry entry;
                entry.mappingId = mapping.id;
                entry.repositoryPath = repositoryPath;
                entry.mappingRelativePath = relativePath;
                entry.size = remote.size;
                entry.selected = remote.size <= mapping.maximumFileBytes &&
                    MatchesPatterns(relativePath,
                        mapping.includePatterns, mapping.excludePatterns);
                entries.push_back(std::move(entry));
            }
        }

        std::sort(entries.begin(), entries.end(),
            [](const BrowserEntry& left, const BrowserEntry& right)
            {
                if (left.mappingId != right.mappingId)
                    return left.mappingId < right.mappingId;
                return left.mappingRelativePath < right.mappingRelativePath;
            });
        return entries;
    }
}
