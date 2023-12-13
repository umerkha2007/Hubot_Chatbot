# Description:
#   Forward only comments from Jira to Slack.
#
# Dependencies:
#   None
#
# Configuration:
#   HUBOT_JIRA_URL
#
# Commands:
#   None
#
# Author:
#   Dennis Newel <dennis.newel@gmail.com>
#
# Modified from the hubot-jira-comment plugin by mnpk <mnncat@gmail.com>

module.exports = (robot) ->
  robot.router.post '/hubot/jira-comment/:room', (req, res) ->
    room = req.params.room
    body = req.body
    issue = "#{body.issue.key} #{body.issue.fields.summary}"
    url = "#{process.env.HUBOT_JIRA_URL}/browse/#{body.issue.key}"
    if body.webhookEvent == 'jira:issue_updated' && body.comment
      if !!~ body.comment.body.indexOf room
        robot.messageRoom room, "*#{issue}* _(#{url})_\n@#{body.comment.author.name}'s comment:\n```#{body.comment.body}```"
      else
        console.log "Comment for #{body.issue.key} didn't include the username"
    
    if body.webhookEvent == 'jira:issue_updated' && body.changelog
        for item in body.changelog.items
            console.log item
            if item.field == "assignee" && item.to && !!~ item.to.indexOf room
                 robot.messageRoom room, "*#{issue}* _(#{url})_\nYou've been assigned this issue"
    res.send 'OK'
