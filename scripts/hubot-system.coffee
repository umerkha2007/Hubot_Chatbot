# Description:
#   Gives system information about Hubot
#
# Dependencies:
#   None
#
# Commands:
#   hubot are you alive - tells if hubot is still alive.
#   hubot tell me more - tells you stuff about the hubot process.
#
# Author:
#   Charles Feval <charles@feval.fr>
#

systemroom = process.env.GITHUB_RESULT_ROOM ? "bender-system"

module.exports = (robot) ->
	robot.messageRoom systemroom, "I have restarted v2!, I'm running on #{process.platform}"

	robot.respond /are you (still )*alive/i, (res) =>
		res.send "Yes I am v2, and I'm running on #{process.platform}."

	robot.respond /tell me more/i, (res) =>
		res.send "My PID is #{process.pid} and I've been working for #{process.uptime()}s."
