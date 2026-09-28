#pragma once

#include "MQ2WebUpdatePlanner.h"
#include "MQ2WebUpdateProfileStore.h"

#include <map>
#include <sstream>

namespace mq2webupdate::stageplan
{
    struct Manifest
    {
        std::string profileId;
        profiles::SourceProvider provider = profiles::SourceProvider::GitHub;
        std::string owner;
        std::string repository;
        std::string reference;
        std::string commitSha;
        std::vector<planner::PlanItem> items;
    };

    inline bool IsHexCommitSha(const std::string& value)
    {
        return value.size() == 40 && std::all_of(
            value.begin(), value.end(), [](unsigned char ch)
            {
                return std::isxdigit(ch) != 0;
            });
    }

    inline std::string Serialize(const Manifest& manifest)
    {
        std::ostringstream output;
        output << "Format=MQ2WebUpdateStagePlan\n";
        output << "Version=1\n";
        output << "ProfileID=" << profiles::EscapeValue(manifest.profileId) << "\n";
        output << "Provider=" << profiles::SourceProviderName(manifest.provider) << "\n";
        output << "Owner=" << profiles::EscapeValue(manifest.owner) << "\n";
        output << "Repository=" << profiles::EscapeValue(manifest.repository) << "\n";
        output << "Reference=" << profiles::EscapeValue(manifest.reference) << "\n";
        output << "CommitSHA=" << manifest.commitSha << "\n";
        output << "ItemCount=" << manifest.items.size() << "\n";

        for (std::size_t i = 0; i < manifest.items.size(); ++i)
        {
            const auto& item = manifest.items[i];
            const std::string prefix = "Item." + std::to_string(i) + ".";
            output << prefix << "MappingID=" << profiles::EscapeValue(item.mappingId) << "\n";
            output << prefix << "RepositoryPath=" << profiles::EscapeValue(item.repositoryPath) << "\n";
            output << prefix << "StagePath=" << profiles::EscapeValue(item.stageRelativePath) << "\n";
            output << prefix << "DestinationRoot="
                << profiles::DestinationRootName(item.destinationRoot) << "\n";
            output << prefix << "DestinationPath="
                << profiles::EscapeValue(item.destinationRelativePath) << "\n";
            output << prefix << "ExpectedSize=" << item.expectedSize << "\n";
            output << prefix << "GitObjectSHA=" << profiles::EscapeValue(item.gitObjectSha) << "\n";
            output << prefix << "RestartRequired=" << (item.restartRequired ? 1 : 0) << "\n";
        }

        return output.str();
    }

    inline bool Parse(
        const std::string& data,
        Manifest& manifest,
        std::string& error)
    {
        std::map<std::string, std::string> fields;
        std::istringstream input(data);
        std::string line;

        while (std::getline(input, line))
        {
            if (!line.empty() && line.back() == '\r') line.pop_back();
            if (line.empty() || line.front() == ';') continue;
            const auto equals = line.find('=');
            if (equals == std::string::npos || equals == 0 ||
                !fields.emplace(line.substr(0, equals), line.substr(equals + 1)).second)
            {
                error = "Malformed or duplicate stage-plan field.";
                return false;
            }
        }

        if (fields["Format"] != "MQ2WebUpdateStagePlan" || fields["Version"] != "1")
        {
            error = "Unsupported stage-plan format.";
            return false;
        }

        auto Decode = [&](const std::string& key, std::string& value)
        {
            const auto found = fields.find(key);
            return found != fields.end() && profiles::UnescapeValue(found->second, value);
        };

        std::string provider;
        std::uint64_t itemCount = 0;
        if (!Decode("ProfileID", manifest.profileId) ||
            !Decode("Provider", provider) ||
            !Decode("Owner", manifest.owner) ||
            !Decode("Repository", manifest.repository) ||
            !Decode("Reference", manifest.reference) ||
            !Decode("CommitSHA", manifest.commitSha) ||
            !profiles::ParseUnsigned(fields["ItemCount"], itemCount) ||
            itemCount > 100000)
        {
            error = "Invalid stage-plan identity.";
            return false;
        }

        const auto parsedProvider = profiles::ParseSourceProvider(provider);
        if (!parsedProvider || !profiles::IsAsciiIdentifier(manifest.profileId) ||
            !profiles::IsGitHubComponent(manifest.owner) ||
            !profiles::IsGitHubComponent(manifest.repository) ||
            !IsHexCommitSha(manifest.commitSha))
        {
            error = "Unsafe stage-plan identity.";
            return false;
        }
        manifest.provider = *parsedProvider;
        manifest.items.clear();

        std::map<std::string, std::string> destinations;
        std::set<std::string> stagePaths;
        for (std::uint64_t i = 0; i < itemCount; ++i)
        {
            planner::PlanItem item;
            item.profileId = manifest.profileId;
            const std::string prefix = "Item." + std::to_string(i) + ".";
            std::string root;
            std::string restart;
            if (!Decode(prefix + "MappingID", item.mappingId) ||
                !Decode(prefix + "RepositoryPath", item.repositoryPath) ||
                !Decode(prefix + "StagePath", item.stageRelativePath) ||
                !Decode(prefix + "DestinationRoot", root) ||
                !Decode(prefix + "DestinationPath", item.destinationRelativePath) ||
                !profiles::ParseUnsigned(fields[prefix + "ExpectedSize"], item.expectedSize) ||
                !Decode(prefix + "GitObjectSHA", item.gitObjectSha) ||
                !Decode(prefix + "RestartRequired", restart))
            {
                error = "Invalid stage-plan item.";
                return false;
            }

            const auto parsedRoot = profiles::ParseDestinationRoot(root);
            bool restartRequired = false;
            if (!parsedRoot || !profiles::ParseBoolean(restart, restartRequired) ||
                !profiles::IsAsciiIdentifier(item.mappingId) ||
                !profiles::IsSafeRelativePath(item.repositoryPath) || item.repositoryPath.empty() ||
                !profiles::IsSafeRelativePath(item.stageRelativePath) || item.stageRelativePath.empty() ||
                !profiles::IsSafeRelativePath(item.destinationRelativePath) || item.destinationRelativePath.empty())
            {
                error = "Unsafe stage-plan item.";
                return false;
            }

            item.destinationRoot = *parsedRoot;
            item.restartRequired = restartRequired;
            const std::string destination = root + "/" + item.destinationRelativePath;
            if (!stagePaths.insert(item.stageRelativePath).second ||
                !destinations.emplace(destination, item.repositoryPath).second)
            {
                error = "Duplicate stage or destination path.";
                return false;
            }
            manifest.items.push_back(std::move(item));
        }

        return true;
    }

    inline bool MatchesProfile(
        const Manifest& manifest,
        const profiles::Profile& profile)
    {
        return manifest.profileId == profile.id &&
            manifest.provider == profile.provider &&
            manifest.owner == profile.owner &&
            manifest.repository == profile.repository &&
            manifest.reference == profile.reference;
    }
}
