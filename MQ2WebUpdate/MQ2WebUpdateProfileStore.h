#pragma once

#include "MQ2WebUpdateProfiles.h"

#include <iomanip>
#include <map>
#include <sstream>

namespace mq2webupdate::profiles
{
    inline std::string EscapeValue(const std::string& value)
    {
        std::ostringstream output;
        output << std::uppercase << std::hex;

        for (unsigned char ch : value)
        {
            if (ch == '%' || ch == '\r' || ch == '\n' || ch == '=' || ch == ';')
            {
                output << '%' << std::setw(2) << std::setfill('0')
                    << static_cast<unsigned int>(ch);
            }
            else
            {
                output << static_cast<char>(ch);
            }
        }

        return output.str();
    }

    inline bool UnescapeValue(
        const std::string& value,
        std::string& output)
    {
        auto Hex = [](char ch) -> int
        {
            if (ch >= '0' && ch <= '9') return ch - '0';
            if (ch >= 'A' && ch <= 'F') return 10 + ch - 'A';
            if (ch >= 'a' && ch <= 'f') return 10 + ch - 'a';
            return -1;
        };

        output.clear();

        for (std::size_t i = 0; i < value.size(); ++i)
        {
            if (value[i] != '%')
            {
                output.push_back(value[i]);
                continue;
            }

            if (i + 2 >= value.size())
                return false;

            const int high = Hex(value[i + 1]);
            const int low = Hex(value[i + 2]);

            if (high < 0 || low < 0)
                return false;

            output.push_back(static_cast<char>((high << 4) | low));
            i += 2;
        }

        return true;
    }

    inline std::string JoinList(const std::vector<std::string>& values)
    {
        std::ostringstream output;

        for (std::size_t i = 0; i < values.size(); ++i)
        {
            if (i != 0)
                output << ';';

            output << EscapeValue(values[i]);
        }

        return output.str();
    }

    inline bool SplitList(
        const std::string& value,
        std::vector<std::string>& output)
    {
        output.clear();
        std::size_t start = 0;

        while (start <= value.size())
        {
            const std::size_t separator = value.find(';', start);
            const std::string encoded = value.substr(
                start,
                separator == std::string::npos
                    ? std::string::npos
                    : separator - start);

            if (!encoded.empty())
            {
                std::string decoded;

                if (!UnescapeValue(encoded, decoded))
                    return false;

                output.push_back(std::move(decoded));
            }

            if (separator == std::string::npos)
                break;

            start = separator + 1;
        }

        return true;
    }

    inline std::string SerializeProfiles(
        const std::vector<Profile>& profiles)
    {
        std::ostringstream output;
        output << "Format=MQ2WebUpdateProfiles\n";
        output << "Version=4\n";
        output << "ProfileCount=" << profiles.size() << "\n";

        for (std::size_t profileIndex = 0;
             profileIndex < profiles.size();
             ++profileIndex)
        {
            const Profile& profile = profiles[profileIndex];
            const std::string prefix =
                "Profile." + std::to_string(profileIndex) + ".";

            output << prefix << "ID=" << EscapeValue(profile.id) << "\n";
            output << prefix << "Name=" << EscapeValue(profile.name) << "\n";
            output << prefix << "Enabled=" << (profile.enabled ? 1 : 0) << "\n";
            output << prefix << "Role=" << ProfileRoleName(profile.role) << "\n";
            output << prefix << "Provider=" << SourceProviderName(profile.provider) << "\n";
            output << prefix << "Private=" << (profile.privateRepository ? 1 : 0) << "\n";
            output << prefix << "Owner=" << EscapeValue(profile.owner) << "\n";
            output << prefix << "Repository=" << EscapeValue(profile.repository) << "\n";
            output << prefix << "Reference=" << EscapeValue(profile.reference) << "\n";
            output << prefix << "Channel=" << EscapeValue(profile.channel) << "\n";
            output << prefix << "MonitorOnStartup=" << (profile.monitorOnStartup ? 1 : 0) << "\n";
            output << prefix << "MonitorIntervalMinutes=" << profile.monitorIntervalMinutes << "\n";
            output << prefix << "NotificationsEnabled=" << (profile.notificationsEnabled ? 1 : 0) << "\n";
            output << prefix << "AcknowledgedSHA=" << EscapeValue(profile.acknowledgedSha) << "\n";
            output << prefix << "MappingCount=" << profile.mappings.size() << "\n";

            for (std::size_t mappingIndex = 0;
                 mappingIndex < profile.mappings.size();
                 ++mappingIndex)
            {
                const Mapping& mapping = profile.mappings[mappingIndex];
                const std::string mappingPrefix = prefix +
                    "Mapping." + std::to_string(mappingIndex) + ".";

                output << mappingPrefix << "ID=" << EscapeValue(mapping.id) << "\n";
                output << mappingPrefix << "Name=" << EscapeValue(mapping.name) << "\n";
                output << mappingPrefix << "Enabled=" << (mapping.enabled ? 1 : 0) << "\n";
                output << mappingPrefix << "Recursive=" << (mapping.recursive ? 1 : 0) << "\n";
                output << mappingPrefix << "Required=" << (mapping.required ? 1 : 0) << "\n";
                output << mappingPrefix << "RestartRequired=" << (mapping.restartRequired ? 1 : 0) << "\n";
                output << mappingPrefix << "RemotePath=" << EscapeValue(mapping.remotePath) << "\n";
                output << mappingPrefix << "DestinationRoot="
                    << DestinationRootName(mapping.destinationRoot) << "\n";
                output << mappingPrefix << "DestinationPath="
                    << EscapeValue(mapping.destinationPath) << "\n";
                output << mappingPrefix << "Include=" << JoinList(mapping.includePatterns) << "\n";
                output << mappingPrefix << "Exclude=" << JoinList(mapping.excludePatterns) << "\n";
                output << mappingPrefix << "MaximumFileBytes=" << mapping.maximumFileBytes << "\n";
            }
        }

        return output.str();
    }

    inline bool ParseBoolean(const std::string& value, bool& output)
    {
        if (value == "1") { output = true; return true; }
        if (value == "0") { output = false; return true; }
        return false;
    }

    inline bool ParseUnsigned(
        const std::string& value,
        std::uint64_t& output)
    {
        try
        {
            std::size_t consumed = 0;
            output = std::stoull(value, &consumed);
            return consumed == value.size();
        }
        catch (...)
        {
            return false;
        }
    }

    inline bool ParseProfileStore(
        const std::string& data,
        std::vector<Profile>& profiles,
        std::string& error)
    {
        std::map<std::string, std::string> fields;
        std::istringstream input(data);
        std::string line;

        while (std::getline(input, line))
        {
            if (!line.empty() && line.back() == '\r')
                line.pop_back();

            if (line.empty() || line.front() == ';')
                continue;

            const std::size_t equals = line.find('=');

            if (equals == std::string::npos || equals == 0)
            {
                error = "Malformed profile-store line.";
                return false;
            }

            if (!fields.emplace(line.substr(0, equals), line.substr(equals + 1)).second)
            {
                error = "Duplicate profile-store field.";
                return false;
            }
        }

        const bool version1 = fields["Version"] == "1";
        const bool version2 = fields["Version"] == "2";
        const bool version3 = fields["Version"] == "3";
        const bool version4 = fields["Version"] == "4";

        if (fields["Format"] != "MQ2WebUpdateProfiles" ||
            (!version1 && !version2 && !version3 && !version4))
        {
            error = "Unsupported profile-store format or version.";
            return false;
        }

        std::uint64_t profileCount = 0;

        if (!ParseUnsigned(fields["ProfileCount"], profileCount) || profileCount > 128)
        {
            error = "Invalid profile count.";
            return false;
        }

        std::vector<Profile> parsed;

        auto Decode = [&](const std::string& key, std::string& value) -> bool
        {
            const auto found = fields.find(key);
            return found != fields.end() && UnescapeValue(found->second, value);
        };

        for (std::uint64_t profileIndex = 0;
             profileIndex < profileCount;
             ++profileIndex)
        {
            Profile profile;
            const std::string prefix =
                "Profile." + std::to_string(profileIndex) + ".";
            std::uint64_t mappingCount = 0;
            std::string role;
            std::string provider = "github";

            if (!Decode(prefix + "ID", profile.id) ||
                !Decode(prefix + "Name", profile.name) ||
                !ParseBoolean(fields[prefix + "Enabled"], profile.enabled) ||
                !Decode(prefix + "Role", role) ||
                !ParseBoolean(fields[prefix + "Private"], profile.privateRepository) ||
                !Decode(prefix + "Owner", profile.owner) ||
                !Decode(prefix + "Repository", profile.repository) ||
                !Decode(prefix + "Reference", profile.reference) ||
                !Decode(prefix + "Channel", profile.channel) ||
                !ParseUnsigned(fields[prefix + "MappingCount"], mappingCount) ||
                mappingCount > 256)
            {
                error = "Invalid profile fields.";
                return false;
            }

            if ((version2 || version3 || version4) && !Decode(prefix + "Provider", provider))
            {
                error = "Invalid profile provider field.";
                return false;
            }

            const auto parsedRole = ParseProfileRole(role);

            const auto parsedProvider = ParseSourceProvider(provider);

            if (!parsedRole || !parsedProvider)
            {
                error = "Invalid profile role or provider.";
                return false;
            }

            profile.role = *parsedRole;
            profile.provider = *parsedProvider;

            if (version3 || version4)
            {
                std::uint64_t interval = 0;
                if (!ParseBoolean(fields[prefix + "MonitorOnStartup"], profile.monitorOnStartup) ||
                    !ParseUnsigned(fields[prefix + "MonitorIntervalMinutes"], interval) ||
                    interval > 10080 ||
                    !ParseBoolean(fields[prefix + "NotificationsEnabled"], profile.notificationsEnabled) ||
                    !Decode(prefix + "AcknowledgedSHA", profile.acknowledgedSha))
                {
                    error = "Invalid repository monitoring fields.";
                    return false;
                }
                profile.monitorIntervalMinutes = static_cast<std::uint32_t>(interval);
            }

            for (std::uint64_t mappingIndex = 0;
                 mappingIndex < mappingCount;
                 ++mappingIndex)
            {
                Mapping mapping;
                const std::string mappingPrefix = prefix +
                    "Mapping." + std::to_string(mappingIndex) + ".";
                std::string root;
                std::uint64_t maximumBytes = 0;

                if (!Decode(mappingPrefix + "ID", mapping.id) ||
                    !Decode(mappingPrefix + "Name", mapping.name) ||
                    !ParseBoolean(fields[mappingPrefix + "Enabled"], mapping.enabled) ||
                    !ParseBoolean(fields[mappingPrefix + "Recursive"], mapping.recursive) ||
                    !ParseBoolean(fields[mappingPrefix + "Required"], mapping.required) ||
                    !ParseBoolean(fields[mappingPrefix + "RestartRequired"], mapping.restartRequired) ||
                    !Decode(mappingPrefix + "RemotePath", mapping.remotePath) ||
                    !Decode(mappingPrefix + "DestinationRoot", root) ||
                    !Decode(mappingPrefix + "DestinationPath", mapping.destinationPath) ||
                    !SplitList(fields[mappingPrefix + "Include"], mapping.includePatterns) ||
                    !SplitList(fields[mappingPrefix + "Exclude"], mapping.excludePatterns) ||
                    !ParseUnsigned(fields[mappingPrefix + "MaximumFileBytes"], maximumBytes))
                {
                    error = "Invalid mapping fields.";
                    return false;
                }

                const auto parsedRoot = ParseDestinationRoot(root);

                if (!parsedRoot)
                {
                    error = "Invalid mapping destination root.";
                    return false;
                }

                mapping.destinationRoot = *parsedRoot;
                mapping.maximumFileBytes = maximumBytes;
                profile.mappings.push_back(std::move(mapping));
            }

            const ValidationResult validation = ValidateProfile(profile);

            if (!validation.IsValid())
            {
                error = validation.errors.front().field + ": " +
                    validation.errors.front().message;
                return false;
            }

            parsed.push_back(std::move(profile));
        }

        const ValidationResult setValidation = ValidateProfileSet(parsed);

        if (!setValidation.IsValid())
        {
            error = setValidation.errors.front().field + ": " +
                setValidation.errors.front().message;
            return false;
        }

        profiles = std::move(parsed);
        error.clear();
        return true;
    }
}
