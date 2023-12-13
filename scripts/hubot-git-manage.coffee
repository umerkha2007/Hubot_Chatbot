# Description:
#   Supports the atomic change flow branching model.
#   Several commands to manage branches, plus a endpoint for Jira to create branches.
#   You should use the configuration as follows:
#     - GITHUB_ROOT_BRANCH is the source of truth (e.g. master)
#     - GITHUB_PASSWORD is a bot password for GITHUB
#     - GITHUB_USER is the bot username
#     - GITHUB_REPOSITORY is the company account username, ie. your upstream account. This will default to GITHUB_USER if not
#       specified (effectively using the user's own repository)
#     - GITHUB_REPOSITORIES is the list of repositories in that account where you want. This will default to GITHUB_REPOSITORY,
#       cause with some luck you gave the default repo
#       to create branches.
#     - GITHUB_HISTORY_RETENTION sets the number of log entries to keep for a given branch. Defaults to 250
#     - GITHUB_HISTORY_DEFAULT sets the number of log entries to show by default. Defaults to 15
#   This also sets a Jira webhook to point to [url]/epic-started/${id}
#
# Dependencies:
#   github
#   coffee-script
#   promise
#
# Commands:
#   hubot merge <workbranch> into <basebranch> [with comment <comment>] - Merge work into base (after confirmation) with an optional comment. If you ommit the comment, Hubot will make up one.
#   hubot wipe <workbranch> - Delete _workbranch_ and restore it from the configured root branch
#   hubot nuke <workbranch> - Same as wipe
#   hubot list branches - lists all the branches accross the configured repositories
#   hubot remerge <branch> - remerge all branches merged into this one.
#   hubot what's on <branch name> - lists all branches merged in branch name from Hubot. Also works with what is, who is, who's, etc.
#   hubot create branch <branch name> - initializes a new branch from master
#   hubot (show me the )(last <x> entries [in|of]) history of <branch name> - shows the history of a given branch
#
# Author:
#   Charles Feval <charles@feval.ca>

module.exports = (robot) ->
# This is all the configuration retrieved from environment
  rootbranch = process.env.GITHUB_ROOT_BRANCH ? "master"
  holdingTempBranch = process.env.GITHUB_HOLDING_TEMP_BRANCH ? "holdingtemp"
  holdingBranchPattern = process.env.GITHUB_HOLDING_BRANCH_REGEX ? "^holding\\d?\\d?$"
  gituser = process.env.GITHUB_USER ? ""
  repouser = process.env.GITHUB_REPOSITORY ? gituser
  repositories = if process.env.GITHUB_REPOSITORIES then process.env.GITHUB_REPOSITORIES.split "," else [repouser]
  history = {}
  history.retention = process.env.GITHUB_HISTORY_RETENTION ? 250
  history.default = process.env.GITHUB_HISTORY_DEFAULT ? 15
  adminList = process.env.HUBOT_AUTH_ADMIN
  personalAccessToken = process.env.GITHUB_PERSONAL_ACCESS_TOKEN

# This is just a utility function to combine strings. There are packages doing that in npm but this is simple enough that I prefer not creating a dependency
  combine = ([head, tail...], combiner) -> if tail is null or tail.length == 0 then head else "#{head}#{combiner ? "\n"}#{combine tail, combiner}"

  isRegisteredSlackUser = (userId) =>
    # hubot's robot.auth.isAdmin method isn't working as normal. This is temporary fix while we upgrade all of bender.
    return adminList.split(",").indexOf(userId) > -1

  getSplitBranches = (msg) =>
    return msg.split(",")
# Connector to github using https://www.npmjs.com/package/github
# config should contain the following:
# gituser: user to connect to git
# gitpassword: password to connect to git
# repouser: Name of the user containing the repositories (e.g. VRXMediaValet)
  gitConnector = (config) ->
    OctokitAPI = require "@octokit/rest"
    Promise = require "promise"
    github = new OctokitAPI.Octokit({
      auth: personalAccessToken
      timeout: 5000
      baseUrl: 'https://api.github.com',
      pathPrefix: ""
      headers: {
        "user-agent": "hubot-branch-creator"
      }
      log: console
      })

    data = github.rest.users.getAuthenticated();
    console.log("Hello, %s", data);
    # github = new GitHubApi {
    #   version: "3.0.0"
    #   debug: false
    #   protocol: "https"
    #   host: "api.github.com"
    #   pathPrefix: ""
    #   timeout: 5000
    #   headers: {
    #     "user-agent": "hubot-branch-creator"
    #   }
    # }


    createpromises = (repository, basebranch, workbranch) -> {
      getReferences: () -> (Promise.denodeify github.rest.repos.listBranchesForHeadCommit) {
        user: config.repouser
        repo: repository
      }

    }

# This is the object returned by the github connector thingy. It's linking promises together and calling the callback in return.
    {
      getReferences: (repository, callback, errorcallback) ->
        promises = createpromises(repository, "basebranch", "changedbranch")
        promises.getReferences()
          .then callback,
          (error) -> errorcallback "Error while getting list of references: #{JSON.parse(error).message}"

      createReference: (repository, workbranch, baseReference) -> (Promise.denodeify github.rest.git.createRef) {
        owner: config.repouser
        repo: repository
        ref: "refs/heads/#{workbranch}"
        sha: baseReference.object.sha
      }

      getReference: (repository, basebranch) -> (Promise.denodeify github.rest.git.getRef) {
        owner: config.repouser
        repo: repository
        ref: "heads/#{basebranch}"
      }

      merge: (repository, basebranch, changedbranch, comment, callback, errorcallback) -> (Promise.denodeify github.rest.repos.merge) {
        owner: config.repouser
        repo: repository
        base: "refs/heads/#{basebranch}"
        head: "refs/heads/#{changedbranch}"
        commit_message: comment
      }

      createBranch: (repository, referencebranch, newbranch, callback, errorcallback) ->
        promises = createpromises(repository, referencebranch, newbranch)
        connector.getReference(repository, referencebranch)
          .then (res) =>
            connector.createReference(repository, newbranch, res.data)
          , (error) -> errorcallback "Error while retrieving #{referencebranch} for #{repository}: #{error}"
          .then callback
          , (error) -> errorcallback "Error while creating #{newbranch} for #{repository}: #{error}"

      recreateBranch: (repository, basebranch, branch, callback, errorcallback) -> (Promise.denodeify github.rest.git.deleteRef) {
        owner: config.repouser
        repo: repository
        ref: "heads/#{branch}"
      }
    }

# Saves what branch is on what branch
  class EpicBrain
    constructor: (robot)->
      @brain = robot.brain
      if @brain.data.branches is undefined
        @brain.data.branches = { }
        @brain.save()
        console.log "Current state of branches has been created"

      if @brain.data.branchHistory is undefined
        @brain.data.branchHistory = {}
        @brain.save()
        console.log "History state of branches has been created"

    date: ()->
      pad = (number) -> (if number < 10 then "0" else "") + "#{number}"
      date = new Date()
      "#{date.getFullYear()}-#{pad(date.getMonth() + 1)}-#{pad(date.getDate())} #{pad(date.getHours())}:#{pad(date.getMinutes())}:#{pad(date.getSeconds())}"

    addEpicToBranch: (basebranch, workbranch, repo, user) =>
      branchlist = @getBranches(basebranch)
      branchlist.push workbranch if (branchlist.indexOf workbranch) < 0
      branchHistory = @getHistory basebranch
      branchHistory.push
        date: @date()
        operation:
          type: "merge"
          branch: workbranch
          repository: repo
        user: user
        state: branchlist.slice(0)

      @trimHistory(basebranch)
      @brain.save()
      console.log "#{workbranch} has been merged into #{basebranch}"

    clearEpicsFromBranch: (basebranch, repo, user) =>
      @brain.data.branches[basebranch] = [rootbranch]
      branchHistory = @getHistory basebranch
      branchHistory.push
        date: @date()
        operation:
          type: "wipe"
          repository: repo
        user: user
        state: [rootbranch]

      @trimHistory(basebranch)
      @brain.save()
      console.log "#{basebranch} has been reset"

    remergeEpic: (basebranch, repo, user) =>
      branchHistory = @getHistory basebranch
      branchHistory.push
        date: @date()
        operation:
          type: "refresh"
          repository: repo
        user: user
        state: (@getBranches basebranch).slice(0)

      @trimHistory(basebranch)
      @brain.save()
      console.log "#{basebranch} has been reset"

# @jason: This is to prevent accessing directly to the brain, you go through this get method call.
    getBranches: (basebranch) =>
      @brain.data.branches[basebranch] = [rootbranch] if !@brain.data.branches[basebranch]
      @brain.data.branches[basebranch]

    getHistory: (basebranch) =>
      @brain.data.branchHistory[basebranch] = [] if !@brain.data.branchHistory[basebranch]
      @brain.data.branchHistory[basebranch]

    trimHistory: (basebranch) =>
      limit = (array) ->
        if array.length > history.retention
          array.slice (array.length - history.retention - 1), (array.length - 1)
        else
          array
      @brain.data.branchHistory[basebranch] = limit @brain.data.branchHistory[basebranch]

# caches an operation until it's validated by the user. So for example if you ask for a merge, it's gonna cache the merge
# in there, and ask you to confirm. If you say yes, it will retrieve the operation cached here for your user, then execute it.
  operationcache = {}
  operationKey = (msg) -> msg.message.user.name # use that to calculate key for operation cache

# instanciating variables
  connector = gitConnector { repouser: repouser }
  brain = new EpicBrain robot

  robot.respond /merge (.*) (into|to) ([^\ ]*)( with comment (.*))?/i, (msg) =>
    console.log "initiating merge"
    return msg.reply "You do not have the proper permissions for this action (id: #{msg.message.user.id})" unless isRegisteredSlackUser(msg.message.user.id)
    basebranch = msg.match[3]
    workbranch = msg.match[1]
    workbranch = workbranch.replace "\u2014", "--"
    workbranchesArray = workbranch.split(",").map((workbranch) ->
      workbranch.trim()
    ).filter(Boolean)
    comment = msg.match[5]
    if basebranch is rootbranch and comment is undefined
      return msg.reply "You want to merge to #{basebranch} without a comment? :monkey: I don't think so! (Use 'with comment bla bla bla')"
    console.log("workbranchesArray: ", workbranchesArray)
    combinedBranchesMessage = combine (":arrow_lower_right: #{singleWorkBranch}" for singleWorkBranch in workbranchesArray), "\n"
    msg.reply "Are you sure you want to merge:\n" + combinedBranchesMessage + "\nto #{basebranch}:question:"
    # this is just defining what merging actualy is. Not directly doing the operation, as this is gonna be
    # cached until the user confirms.
    merge = () =>
      msg.send "Ok, merging #{workbranch} to #{basebranch}"
      mergeFunc = (repo, singleWorkBranch) =>
        # Needed to owerwrite comment inside loops with the default message if multi merging, otherwise it gets accumulated on every iteration
        if workbranchesArray.length > 1
          comment = ":monkey_face: #{msg.message.user.name}: " + "merged #{singleWorkBranch} into #{basebranch} :+1:"
        console.log(repo, basebranch, singleWorkBranch, comment)
        connector.merge(repo, basebranch, singleWorkBranch, comment)
          .then =>
            msg.send ":arrow_lower_right: I merged #{singleWorkBranch} into #{basebranch} for #{repo}"
            console.log("Evaluating Regex: #{holdingBranchPattern}")
            if singleWorkBranch.match(holdingBranchPattern) || singleWorkBranch.match(holdingTempBranch)
              for epic in brain.getBranches singleWorkBranch
                brain.addEpicToBranch basebranch, epic, repo, msg?.message?.user?.name
            else
              brain.addEpicToBranch basebranch, singleWorkBranch, repo, msg?.message?.user?.name
          .catch (error) =>
            msg.reply ":x: Error while merging *#{singleWorkBranch}* into *#{basebranch}* for *#{repo}*: #{error}"
      for repo in repositories
        for singleWorkBranch in workbranchesArray
          (mergeFunc repo, singleWorkBranch)
    if basebranch is rootbranch
      # Assign user comment before going into loops
      comment = ":monkey_face: #{msg.message.user.name}: " + comment
      # we actually ask a second confirmation, so we encapsulate the operation into another operation.
      operationcache[operationKey(msg)] = () ->
        msg.reply ":warning: You're about to push to the root branch (a.k.a. #{rootbranch}), are you reaaaally sure:question:"
        operationcache[operationKey(msg)] = merge
    else
      # Assign user comment or default comment before going into loops
      comment = ":monkey_face: #{msg.message.user.name}: " + (comment ? "merged #{workbranch} into #{basebranch} :+1:")
      operationcache[operationKey(msg)] = merge

  robot.respond /(nuke|wipe) (.*)/i, (msg) =>
    return unless msg.match[2]
    return msg.reply "You do not have the proper permissions for this action " unless isRegisteredSlackUser(msg.message.user.id)
    workbranch = msg.match[2]
    return msg.reply ":no_entry: Nope, #{workbranch} is the root branch, I'm not wiping that. " if workbranch is rootbranch
    msg.reply ":bomb: Are you sure you want to wipe #{workbranch}:question: It will be reconstructed from #{rootbranch} :construction_worker: "
    recreate = () =>
      msg.send ":bomb: Ok, wiping #{workbranch} and rebuilding it from #{rootbranch}"
      recreateFunc = (repo) =>
        connector.recreateBranch(repo, rootbranch, workbranch)
          .then =>
            connector.getReference(repo, rootbranch)
              .then (res) =>
                connector.createReference(repo, workbranch, res.data)
                  .then =>
                    try
                      brain.clearEpicsFromBranch workbranch, repo, msg?.message?.user?.name
                      msg.send ":construction_worker: I reconstructed #{workbranch} from #{rootbranch} in repo #{repo}"
                    catch e
                      msg.reply e
                      console.log e
                  .catch(error) =>
                    msg.reply "Error while getting branch #{rootbranch} for #{repo}: #{error}"
              .catch (error) =>
                if (error instanceof ReferenceError)
                  console.log('reference error in recreateFunc')
                else
                  msg.reply "Error while deleting #{workbranch} for #{repo}: #{error}"
          .catch (error) =>
            msg.reply "Error while creating branch #{workbranch} from #{rootbranch} for #{repo}: #{error}"

      recreateFunc repo for repo in repositories
    operationcache[operationKey(msg)] = recreate


  robot.respond /create branch ([a-zA-Z0-9-_.]+)/i, (msg) =>
      return unless msg.match[1]
      return msg.reply "You do not have the proper permissions for this action " unless (isRegisteredSlackUser(msg.message.user.id))
      workbranch = msg.match[1]
      return msg.reply "Nope, #{workbranch} is the root branch, I'm not creating that. " unless workbranch != rootbranch
      msg.reply "Are you sure you want to create #{workbranch}? :construction_worker: It will be constructed from #{rootbranch}"
      create = () =>
        msg.send "Ok, creating #{workbranch} from #{rootbranch}"
        createFunc = (repo) =>
          connector.createBranch repo, rootbranch, workbranch,
            () =>
              brain.clearEpicsFromBranch workbranch, repo, msg?.message?.user?.name
              msg.send "I constructed #{workbranch} from #{rootbranch} in repo #{repo}"
              ,
            (error) => msg.reply ":x: #{error}"
        createFunc repo for repo in repositories
      operationcache[operationKey(msg)] = create


  robot.respond /list (branch|branches|references)/i, (msg) ->
    branches = {}
    # List the repositories in which branches are present.
    getReferences = (repo, callback) -> connector.getReferences repo,
      (references) ->
        for reference in references
          if branches[reference.name]
            branches[reference.name].push repo
          else
            branches[reference.name] = [repo]
        callback()
      ,(error) -> msg.reply error
    displayBranches = ->
      # See http://coffeescript.org/#loops
      # see http://coffeescript.org/#expressions
      msg.send combine((":heavy_minus_sign: *#{branch}*: _#{combine repos, "_, _"}_" for branch, repos of branches).sort(), "\n")
    # This is a recursive function that's gonna use itself as a callback. This way, we iterate through the repositories
    # but in the end we send only one message with all the branches.
    getRec = ([repo, repos...]) -> # Check there: http://coffeescript.org/#splats
      if repos is null or repos.length == 0
      # Last call, the callback will display the branches.
        getReferences repo, ->
          displayBranches()
      else
      # Not last call, the callback will continue iterate through branches.
        getReferences repo, ->
          getRec repos
    getRec repositories


  # matches: history of prout, show me the history of prout, what's the last 16 in history of prout,
  # last 16 entries of the history, etc.
  robot.respond /(show me the |what's the |what is the |)(last ([0-9]+) entries (in|in the|of|of the|) |)history of ([a-zA-Z0-9-_.]+)/i, (msg) ->
    branch = msg.match[5]
    count = msg.match[3] ? history.default
    history = brain.getHistory(branch)
    formatState = (entry) ->
      comb = ([head, tail...]) ->
        head = "*#{head}*" if head is entry.operation.branch
        if tail is null or tail.length == 0
          head
        else
          "#{head}, #{comb tail}"
      "_#{entry.date}_: " + (switch entry.operation.type
        when "merge" then ":arrow_lower_right: "
        when "wipe" then ":bomb: "
        when "refresh" then ":dancers: "
        else "(#{entry.operation.type}) ") + (comb entry.state) + " `(#{entry.user} - #{entry.operation.type})`"
    limit = (array) ->
      if array.length > count
        array.slice (array.length - count - 1), (array.length - 1)
      else
        array
    msg.send combine (
        ("*#{repository}/#{branch}:* \n" + combine (
          formatState(entry) for entry in limit(history.filter (hist) -> hist.operation.repository == repository)
        ), "\n") for repository in repositories
      ), "\n\n"


  robot.respond /(what|who)( is|['’]s) on ([a-zA-Z0-9-_.]+)/i, (msg) ->
    branch = msg.match[3]
    merges = combine (":heavy_minus_sign: *#{epic}*" for epic in brain.getBranches branch), "\n"
    console.log "Merges: #{merges}"
    msg.send "These branches have been merged into #{branch}:\n#{merges}"


  robot.respond /(remerge|refresh) ([a-zA-Z0-9-_.]+)/i, (msg) =>
    basebranch = msg.match[2]
    return msg.reply ":no_entry: Nope, I won't refresh #{basebranch}. " if basebranch is rootbranch
    res = ""
    merge = (repo, epic) =>
      console.log "Merging #{epic} #{repo}"

      connector.merge(repo, basebranch, epic,":recycle: Automerge by #{msg.message.user.name} :monkey_face:")
        .then (res) =>
          msg.send ":arrow_lower_right: I successfully refreshed #{epic} into #{basebranch} for #{repo}"
        .catch (err) =>
          msg.reply ":x: Error while merging *#{epic}* into *#{basebranch}* for *#{repo}*: #{err}"

    # Look closely: this is iterating through repos, then branches, and launching a merge for each combination, then
    # combining this into one message.
    # You'll also receive one message per error.
    msg.send combine (for repo in repositories
      brain.remergeEpic basebranch, repo, msg?.message?.user?.name
      branchesRes = combine (
        for epic in brain.getBranches basebranch
          merge repo, epic
          "_#{epic}_")
        , ", "
      "Refreshed _#{basebranch}_ in *#{repo}* with: #{branchesRes} :dancers:"
      ), "\n"
    branches = brain.getBranches(basebranch)
  #robot.respond /remove ([a-zA-Z0-9-_.]+) (on|from) ([a-zA-Z0-9-_.]+)/i, (msg) =>
    #tempBranch = "holdingtemp"
    #branchToRemove = msg.match[1]
    #baseBranch = msg.match[3]


    #Need to get a list of branches on baseBranch
    #Need to remove matching branch from list
     #if there is no match throw and error
    #Ask for confirmation
    #nuke baseBranch
    #merge branches into temp branch
    #merge tempBranch into baseBranch
    #replace baseBranch in brain with new list
    #delete tempBranch


  robot.respond /yes/i, (msg) ->
    if operationcache[operationKey(msg)]
        # Find the operation cached for the current user, then clear cache, then run the operation.
        # It's important you clear cache before you run the operation, as the operation itself might
        # actually modify the cache (see for example merge to master). If you clear after, you might
        # be deleting what the operation just did.
      func = operationcache[operationKey(msg)]
      operationcache[operationKey(msg)] = null
      func()
    else
      msg.reply "I didn't ask you anything "

  robot.respond /no/i, (msg) ->
    if operationcache[operationKey(msg)]
      msg.send "Ok I'm not gonna do that"
      operationcache[operationKey(msg)] = null
    else
      msg.reply "I didn't ask you anything "


  # This will create a webhook endpoint for jira called epic-started in your endpoint that you can use
  # to create branches in your repos automagically.
  robot.router.post '/hubot/epic-started/:itemid', (req, res) ->
    itemid = req.params.itemid
    body = req.body
    key = body.issue.key
    url = "#{process.env.HUBOT_JIRA_URL}/browse/#{body.issue.key}"
    summary = body.issue.fields.summary
    escaped_summary = summary.replace /[\(\)\[\]\{\}]/g, ""
    escaped_summary = escaped_summary.replace /[^a-zA-Z0-9-_.]/g, "_"
    branch_name = "epic--#{key}--#{escaped_summary}"

    dispatch = (message) -> robot.messageRoom process.env.GITHUB_RESULT_ROOM, message
    dispatch_branch_created = (repository) ->
      (message) -> dispatch "I created a branch for EPIC #{key} on #{repository} there: #{message.url}"

    connector.createBranch repository, rootbranch, branch_name, (dispatch_branch_created repository) for repository in repositories

    res.send 'OK'
