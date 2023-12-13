# Description:
#   Adds mediavalet credentials to hubot's brain
#
# Commands:
#   Add Credentials <domain> <user> <pass> - Will add the user& pass with the 
#   keyvalue domain to the credentials object in hubot's brain
#
# Author:
#   Jason Marshall <jayson.marshall@gmail.com>

module.exports = (robot) ->
    
    robot.respond /add credentials ([^\s]+) ([^\s]+) ([^\s]+)/i, (msg) ->
        # This might be better suited in some init script?
        credentials = {
            "wintertest": ["wintertestadmin@mediavalet.net", "1234test!"]
            } if robot.brain.get "credentials" == undefiend
        
        robot.brain.set "credentials", credentials
        robot.brain.save
        
        console.log "Holy Moly! {escape msg.match[1]}"
        msg.send "Added your credentials"
    