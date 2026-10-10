# NeroMorte EQBC Connection Test

Created By: NeroMorte. Based on RedGuides MQ2EQBC 13aacbe06f6be118de6550225aaef41ab133b830 (upstream source retained in baseline).

Version 20.01-NeroMorte.1 adds bounded IPv4 discovery on UDP 2114, read-only EQBC TLO discovery data, and selective hiding of internal Triune frame echoes. It retains normal EQBC commands, control checks, protocol, chat, echo preferences and the standard server compatibility. Discovery starts on request, takes four seconds and expires its results after fifteen seconds. It polls at most sixteen datagrams per pulse and stores at most thirty-two endpoints.

The BoxNet Connection tab handles discovery, transport selection, control settings, saved reconnect, manual fallback and disconnect. No user slash setup commands are needed. For one reachable passwordless Go server the connection is automatic; multiple servers need a choice and protected servers need a password. UDP discovery and the TCP connection must be permitted by the network/firewall.

The published client release is disabled until the Windows DLL has been built, tested and uploaded. A disabled release never creates a broken updater mapping. Once verified, the existing independent DLL handoff updates the plugin, and the first-install archive includes the exact payload. User/server INIs are not overwritten.
