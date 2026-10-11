#pragma once

#include "MQ2WebUpdateProfiles.h"
#include "MQ2WebUpdatePlanner.h"

#include <memory>
#include <string>

namespace mq2webupdate::providers
{
    struct Request
    {
        std::string url;
        bool requiresAuthentication = false;
    };

    // Provider adapters resolve identities and create read-only acquisition
    // requests. They never choose local destinations or mutate live files.
    class SourceProviderAdapter
    {
    public:
        virtual ~SourceProviderAdapter() = default;

        virtual const char* Name() const = 0;
        virtual Request ResolveReferenceRequest(
            const profiles::Profile& profile) const = 0;
        virtual Request RepositoryTreeRequest(
            const profiles::Profile& profile,
            const std::string& commitSha) const = 0;
        virtual Request FileRequest(
            const profiles::Profile& profile,
            const std::string& commitSha,
            const std::string& repositoryPath) const = 0;
    };

    inline std::string EncodeGitHubPathSegment(const std::string& value)
    {
        static constexpr char Hex[] = "0123456789ABCDEF";
        std::string encoded;

        for (const unsigned char ch : value)
        {
            if (std::isalnum(ch) || ch == '-' || ch == '_' || ch == '.' || ch == '~')
            {
                encoded.push_back(static_cast<char>(ch));
            }
            else
            {
                encoded.push_back('%');
                encoded.push_back(Hex[(ch >> 4) & 0x0f]);
                encoded.push_back(Hex[ch & 0x0f]);
            }
        }

        return encoded;
    }

    inline std::string EncodeRepositoryPath(const std::string& value)
    {
        std::string encoded;
        std::size_t start = 0;

        while (start <= value.size())
        {
            const std::size_t slash = value.find('/', start);
            if (!encoded.empty()) encoded.push_back('/');
            encoded += EncodeGitHubPathSegment(value.substr(
                start,
                slash == std::string::npos ? std::string::npos : slash - start));
            if (slash == std::string::npos) break;
            start = slash + 1;
        }

        return encoded;
    }

    class GitHubProviderAdapter final : public SourceProviderAdapter
    {
    public:
        const char* Name() const override { return "github"; }

        Request ResolveReferenceRequest(
            const profiles::Profile& profile) const override
        {
            return {
                "https://api.github.com/repos/" +
                    EncodeGitHubPathSegment(profile.owner) + "/" +
                    EncodeGitHubPathSegment(profile.repository) + "/commits/" +
                    EncodeGitHubPathSegment(profile.reference),
                profile.privateRepository
            };
        }

        Request RepositoryTreeRequest(
            const profiles::Profile& profile,
            const std::string& commitSha) const override
        {
            return {
                "https://api.github.com/repos/" +
                    EncodeGitHubPathSegment(profile.owner) + "/" +
                    EncodeGitHubPathSegment(profile.repository) + "/git/trees/" +
                    EncodeGitHubPathSegment(commitSha) + "?recursive=1",
                profile.privateRepository
            };
        }

        Request FileRequest(
            const profiles::Profile& profile,
            const std::string& commitSha,
            const std::string& repositoryPath) const override
        {
            // Edited By: NeroMorte - public selected-file downloads do not
            // spend one REST request per blob. Never put tokens in raw URLs.
            // Private profiles retain the authenticated contents API.
            if (!profile.privateRepository)
            {
                return {
                    "https://raw.githubusercontent.com/" +
                        EncodeGitHubPathSegment(profile.owner) + "/" +
                        EncodeGitHubPathSegment(profile.repository) + "/" +
                        EncodeGitHubPathSegment(commitSha) + "/" +
                        EncodeRepositoryPath(repositoryPath),
                    false
                };
            }
            return {
                "https://api.github.com/repos/" +
                    EncodeGitHubPathSegment(profile.owner) + "/" +
                    EncodeGitHubPathSegment(profile.repository) + "/contents/" +
                    EncodeRepositoryPath(repositoryPath) + "?ref=" +
                    EncodeGitHubPathSegment(commitSha),
                profile.privateRepository
            };
        }
    };

    inline std::unique_ptr<SourceProviderAdapter> CreateProviderAdapter(
        profiles::SourceProvider provider)
    {
        switch (provider)
        {
        case profiles::SourceProvider::GitHub:
            return std::make_unique<GitHubProviderAdapter>();
        }

        return {};
    }

    inline bool ParseJsonStringField(
        const std::string& object,
        const std::string& field,
        std::string& value)
    {
        const std::string needle = "\"" + field + "\"";
        const auto key = object.find(needle);
        if (key == std::string::npos) return false;
        const auto colon = object.find(':', key + needle.size());
        const auto quote = colon == std::string::npos
            ? std::string::npos : object.find('"', colon + 1);
        if (quote == std::string::npos) return false;

        value.clear();
        bool escaped = false;
        for (std::size_t i = quote + 1; i < object.size(); ++i)
        {
            const char ch = object[i];
            if (escaped)
            {
                switch (ch)
                {
                case '"': case '\\': case '/': value.push_back(ch); break;
                case 'b': value.push_back('\b'); break;
                case 'f': value.push_back('\f'); break;
                case 'n': value.push_back('\n'); break;
                case 'r': value.push_back('\r'); break;
                case 't': value.push_back('\t'); break;
                default: return false;
                }
                escaped = false;
            }
            else if (ch == '\\')
            {
                escaped = true;
            }
            else if (ch == '"')
            {
                return true;
            }
            else
            {
                value.push_back(ch);
            }
        }
        return false;
    }

    inline bool ParseJsonUnsignedField(
        const std::string& object,
        const std::string& field,
        std::uint64_t& value)
    {
        const std::string needle = "\"" + field + "\"";
        const auto key = object.find(needle);
        if (key == std::string::npos) return false;
        const auto colon = object.find(':', key + needle.size());
        if (colon == std::string::npos) return false;
        std::size_t begin = colon + 1;
        while (begin < object.size() && std::isspace(
            static_cast<unsigned char>(object[begin]))) ++begin;
        std::size_t end = begin;
        while (end < object.size() && std::isdigit(
            static_cast<unsigned char>(object[end]))) ++end;
        if (begin == end) return false;
        try
        {
            std::size_t consumed = 0;
            value = std::stoull(object.substr(begin, end - begin), &consumed);
            return consumed == end - begin;
        }
        catch (...) { return false; }
    }

    inline bool ParseGitHubTreeResponse(
        const std::string& json,
        std::vector<planner::RemoteTreeFile>& files,
        std::string& error)
    {
        files.clear();
        std::size_t position = 0;

        while ((position = json.find("\"path\"", position)) != std::string::npos)
        {
            const auto objectBegin = json.rfind('{', position);
            const auto objectEnd = json.find('}', position);
            if (objectBegin == std::string::npos || objectEnd == std::string::npos)
            {
                error = "Malformed GitHub tree object.";
                return false;
            }

            const std::string object =
                json.substr(objectBegin, objectEnd - objectBegin + 1);
            std::string type;
            std::string path;
            std::string sha;

            if (!ParseJsonStringField(object, "type", type) ||
                !ParseJsonStringField(object, "path", path) ||
                !ParseJsonStringField(object, "sha", sha))
            {
                error = "GitHub tree item is missing required fields.";
                return false;
            }

            if (type == "blob")
            {
                std::uint64_t size = 0;
                if (!ParseJsonUnsignedField(object, "size", size) ||
                    !profiles::IsSafeRelativePath(path) || path.empty())
                {
                    error = "GitHub tree contains an unsafe or invalid blob.";
                    return false;
                }
                files.push_back({ path, size, sha });
            }

            position = objectEnd + 1;
        }

        std::sort(files.begin(), files.end(),
            [](const auto& left, const auto& right)
            {
                return left.repositoryPath < right.repositoryPath;
            });
        files.erase(std::unique(files.begin(), files.end(),
            [](const auto& left, const auto& right)
            {
                return left.repositoryPath == right.repositoryPath;
            }), files.end());
        return true;
    }
}
