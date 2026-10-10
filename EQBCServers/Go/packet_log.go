// Created By: NeroMorte - filter display at command log sites; never discard transport messages.
package eqbc

import "strings"

func isTriunePacket(command string) bool {
	words := strings.Fields(command)
	if len(words) < 4 {
		return false
	}
	return (strings.EqualFold(words[0], "//ac") || strings.EqualFold(words[0], "/ac")) &&
		(strings.EqualFold(words[1], "net") || strings.EqualFold(words[1], "boxnet")) &&
		strings.EqualFold(words[2], "_eqbc")
}

func (eqbc *EQBC) logCommand(command, message string) {
	if !eqbc.showInternalPackets && isTriunePacket(command) {
		return
	}
	eqbc.Log(message)
}
