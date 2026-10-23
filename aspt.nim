import std/algorithm
import std/os
import std/sequtils
import std/strformat
import std/strutils
import std/streams
import std/httpclient
import std/json
import std/asyncdispatch
import std/options
import std/terminal
import yaml


# config path init
let configPath = getHomeDir() / ".config" / "aspt" / "config.yaml"

# config header
const toolHeader = """

     ▄▄▄   ▄▄▄▄ ▄▄▄▄ ▄▄▄▄▄▄ 
    ██▀██ ███▄▄ ██▄█▀  ██   
    ██▀██ ▄▄██▀ ██     ██   

    >_ aernyOS • Solus Package tool
    >_ version 0.8

"""

# release-monitoring API URL for fetches
const
    ReleaseMonitoringApi = "https://release-monitoring.org/api/v2/versions/?project_id="

# Define types r/w objects in yaml
type
    
    Config = object
            recipeDirectory : string
            recipes        : seq[Recipe]
    
    Recipe = object
        name     : string

    RecipeInfo = object
        name: string
        version: string
        mversion: string
        releaseId: int
        monitoring: bool
        isPreRelease: bool
        apiError: string

# Healthcheck and read the current config
proc readConfig(): Config =
    var yamlData: YamlNode
    let configStream = newFileStream(configPath, fmRead)

    if configStream.isNil:
        quit("Failed to load config", 1)

    load(configStream, yamlData)

    try:
        discard yamlData["recipeDirectory"]
        discard yamlData["recipes"]
    except KeyError:
        configStream.close()
        quit("Missing recipeDirectory or recipes key in config.\n\nPlease delete your config.yaml and rerun the aspt init.\nATTENENTION: Your list of tracked packages resets with this!\n", 1)

    configStream.setPosition(0)

    var configRead: Config
    load(configStream, configRead)
    configStream.close()

    result = configRead



proc getLatestVersion(data: JsonNode): RecipeInfo =
    if data.hasKey("version_details") and data["version_details"].len > 0:
        var latestPreRelease = ""

        for entry in data["version_details"]:
            if not entry["pre_release"].getBool():
                return RecipeInfo(
                    mversion: entry["version"].getStr(),
                    isPreRelease: false
                )

            if latestPreRelease == "":
                latestPreRelease = entry["version"].getStr()

        return RecipeInfo(
            mversion: latestPreRelease,
            isPreRelease: latestPreRelease != ""
        )

    if data.hasKey("latest_version"):
        return RecipeInfo(
            mversion: data["latest_version"].getStr(),
            isPreRelease: false
        )

    return RecipeInfo(mversion: "", isPreRelease: false)

# Crawls through all directories and gets the key values
proc crawlRecipes(recipeDirectory: string): seq[RecipeInfo] =
    let recipeDir = recipeDirectory
    for file in walkDirRec(recipeDir):
        if extractFilename(file) in ["stone.yaml", "package.yml"]:
            # copy name & version from stone.yaml
            var yamlDataStone: YamlNode
            let dbStream = newFileStream(file, fmRead)
            if dbStream.isNil:
                continue
            load(dbStream, yamlDataStone)
            dbStream.close()

            let recipeName = yamlDataStone["name"].content
            let recipeVersion = yamlDataStone["version"].content

            # copy release.id from monitoring.yaml
            let monitoringPath = parentDir(file) / "monitoring.yaml"

            var monitoringBool = false
            var recipeId = 0
            var recipeMversion = ""

            let monStream = newFileStream(monitoringPath, fmRead)
            if not monStream.isNil:
                monitoringBool = true

                var yamlDataMonitoring: YamlNode
                load(monStream, yamlDataMonitoring)
                monStream.close()

                try:
                    let releasesId = yamlDataMonitoring["releases"]["id"].content
                    if releasesId != "~" and releasesId != "null" and releasesId != "":
                        recipeId = parseInt(releasesId)
                except KeyError, ValueError:
                    discard

            # Write all into type
            result.add(RecipeInfo(
                name: recipeName,
                version: recipeVersion,
                mversion: recipeMversion,
                releaseId: recipeId,
                monitoring: monitoringBool
            ))

# # Format version strings to make them comparable
# proc parseVersionParts(version: string): Option[seq[int]] =
#     var normalized = version.strip()
# 
#     if normalized.len == 0:
#         return none(seq[int])
# 
#     # Remove a leading v or V when followed by a digit.
#     if normalized.len > 1 and
#         (normalized[0] == 'v' or normalized[0] == 'V') and
#         normalized[1] in {'0'..'9'}:
#         normalized = normalized[1 .. ^1]
# 
#     # Remove common build and git suffixes.
#     normalized = normalized.split('+')[0]
#     normalized = normalized.split('~')[0]
# 
#     # Prefer a dotted numeric version when one exists.
#     # This handles date/build prefixes such as:
#     # 2026_10_02_10.15.0 -> 10.15.0
#     var dottedStart = -1
#     var dottedEnd = -1
# 
#     for index, character in normalized:
#         if character notin {'0'..'9'}:
#             continue
# 
#         # Find the beginning of a numeric component at a valid boundary.
#         if index > 0 and normalized[index - 1] in {'0'..'9'}:
#             continue
# 
#         if index > 0 and normalized[index - 1] notin {'-', '_', '/', 'v', 'V'}:
#             continue
# 
#         var endIndex = index
#         var dotCount = 0
#         
#         while endIndex < normalized.len:
#             if normalized[endIndex] in {'0'..'9'}:
#                 inc endIndex
#             elif normalized[endIndex] == '.' and
#                 endIndex + 1 < normalized.len and
#                 normalized[endIndex + 1] in {'0'..'9'}:
#                 inc dotCount
#                 inc endIndex
#             else:
#                 break
# 
#         if dotCount > 0 and endIndex > index and
#             normalized[endIndex - 1] in {'0'..'9'}:
#             # Keep the last matching dotted numeric version.
#             dottedStart = index
#             dottedEnd = endIndex
# 
#     if dottedStart >= 0:
#         normalized = normalized[dottedStart ..< dottedEnd]
#     else:
#         var versionStart = -1
# 
#         # Match known version markers, but only at valid boundaries.
#         for marker in ["stable", "release-", "release", "VERSION_", "-v"]:
#             var searchEnd = normalized.len
# 
#             while searchEnd > 0:
#                 let markerPos = normalized.rfind(marker, 0, searchEnd - 1)
# 
#                 if markerPos < 0:
#                     break
# 
#                 let candidate = markerPos + marker.len
#                 let markerHasBoundary =
#                     markerPos == 0 or
#                     normalized[markerPos - 1] in {'-', '_', '/'}
# 
#                 if markerHasBoundary and
#                     candidate < normalized.len and
#                     normalized[candidate] in {'0'..'9'}:
#                     versionStart = candidate
#                     break
# 
#                 searchEnd = markerPos
# 
#             if versionStart >= 0:
#                 break
# 
#         # Otherwise, find a digit sequence at the beginning or after
#         # a separator. This avoids digits embedded in package names.
#         if versionStart == -1:
#             for index, character in normalized:
#                 if character in {'0'..'9'} and
#                     (index == 0 or normalized[index - 1] in {'-', '_', '/'}):
#                     versionStart = index
#                     break
# 
#         if versionStart == -1:
#             return none(seq[int])
# 
#         normalized = normalized[versionStart .. ^1]
# 
#         # Keep numeric components separated by dots or underscores.
#         var versionEnd = 0
#         while versionEnd < normalized.len and
#             (normalized[versionEnd] in {'0'..'9'} or
#              normalized[versionEnd] in {'.', '_'}):
#             inc versionEnd
# 
#         if versionEnd == 0:
#             return none(seq[int])
# 
#         normalized = normalized[0 ..< versionEnd].replace('_', '.')
# 
#     var parts: seq[int] = @[]
# 
#     for part in normalized.split('.'):
#         if part.len == 0:
#             return none(seq[int])
# 
#         try:
#             parts.add(parseInt(part))
#         except ValueError:
#             return none(seq[int])
# 
#     if parts.len == 0:
#         return none(seq[int])
# 
#     return some(parts)
# 
# 
# proc isNewerVersion(current, latest: string): bool =
#     let currentParts = parseVersionParts(current)
#     let latestParts = parseVersionParts(latest)
# 
#     # If either version cannot be parsed, don't claim an update.
#     if currentParts.isNone or latestParts.isNone:
#         return false
# 
#     let count = max(currentParts.get.len, latestParts.get.len)
# 
#     for i in 0 ..< count:
#         let currentPart =
#             if i < currentParts.get.len: currentParts.get[i] else: 0
# 
#         let latestPart =
#             if i < latestParts.get.len: latestParts.get[i] else: 0
# 
#         if latestPart > currentPart:
#             return true
# 
#         if latestPart < currentPart:
#             return false
# 
#     return false
# 
# proc canCompareVersions(current, latest: string): bool =
#     parseVersionParts(current).isSome and
#     parseVersionParts(latest).isSome



proc parseVersionParts(version: string): Option[seq[int]] =
    let normalized = version.strip()
        .split('+')[0]
        .split('~')[0]

    if normalized.len == 0:
        return none(seq[int])

    # Extract a numeric sequence containing at least one dot.
    # Examples: v1.2.3, go1.27.3, seatd 0.9.3, release-1.2.3
    var bestStart = -1
    var bestEnd = -1
    var bestDotCount = 0

    for start, ch in normalized:
        if ch notin {'0'..'9'}:
            continue

        # Start only at the beginning of a numeric component.
        if start > 0 and normalized[start - 1] in {'0'..'9'}:
            continue

        var finish = start
        var dotCount = 0

        while finish < normalized.len:
            if normalized[finish] in {'0'..'9'}:
                inc finish
            elif normalized[finish] == '.' and
                finish + 1 < normalized.len and
                normalized[finish + 1] in {'0'..'9'}:
                inc dotCount
                inc finish
            else:
                break

        if dotCount > bestDotCount:
            bestStart = start
            bestEnd = finish
            bestDotCount = dotCount

    var candidate: string

    if bestStart >= 0:
        candidate = normalized[bestStart ..< bestEnd]
    else:
        # No dotted version: find the first numeric sequence
        # at the beginning or after a common separator/prefix.
        var start = -1

        for i, ch in normalized:
            if ch notin {'0'..'9'}:
                continue

            if i == 0 or normalized[i - 1] in {'-', '_', '/', ' ', 'v', 'V', 'r', 'R'}:
                start = i
                break

        if start < 0:
            return none(seq[int])

        var finish = start
        while finish < normalized.len and
            normalized[finish] in {'0'..'9'}:
            inc finish

        candidate = normalized[start ..< finish]

    # Convert the extracted components to integers.
    # Underscores are accepted as separators in numeric versions.
    candidate = candidate.replace('_', '.')

    var parts: seq[int] = @[]

    for part in candidate.split('.'):
        if part.len == 0:
            return none(seq[int])

        try:
            parts.add(parseInt(part))
        except ValueError:
            return none(seq[int])

    if parts.len == 0:
        return none(seq[int])

    return some(parts)


proc isNewerVersion(current, latest: string): bool =
    let currentParts = parseVersionParts(current)
    let latestParts = parseVersionParts(latest)

    if currentParts.isNone or latestParts.isNone:
        return false

    let count = max(currentParts.get.len, latestParts.get.len)

    for i in 0 ..< count:
        let currentPart =
            if i < currentParts.get.len: currentParts.get[i] else: 0

        let latestPart =
            if i < latestParts.get.len: latestParts.get[i] else: 0

        if latestPart > currentPart:
            return true

        if latestPart < currentPart:
            return false

    return false


proc canCompareVersions(current, latest: string): bool =
    parseVersionParts(current).isSome and
    parseVersionParts(latest).isSome



proc printVersionTable(checkResults: var seq[RecipeInfo], outdatedOnly: bool = false) =
    checkResults.sort(
        proc(a, b: RecipeInfo): int =
            cmp(a.name, b.name)
    )

    var nameWidth = "name".len
    var versionWidth = "current".len
    let updateWidth = "update".len
    var latestWidth = "latest".len

    for recipe in checkResults:
        if outdatedOnly and recipe.apiError == "" and canCompareVersions(recipe.version, recipe.mversion) and not isNewerVersion(recipe.version, recipe.mversion):
            continue

        let comparisonUnknown =
            recipe.apiError == "" and
            recipe.mversion.len > 0 and
            not canCompareVersions(recipe.version, recipe.mversion)

        let latest =
            if recipe.apiError != "":
                "Error: " & recipe.apiError
            elif comparisonUnknown:
                recipe.mversion & " (version comparison unknown)"
            elif recipe.isPreRelease:
                recipe.mversion & " (pre-release)"
            else:
                recipe.mversion

        nameWidth = max(nameWidth, recipe.name.len)
        versionWidth = max(versionWidth, recipe.version.len)
        latestWidth = max(latestWidth, latest.len)

    # header
    echo alignLeft("name", nameWidth), "  | ",
         alignLeft("current", versionWidth), "  | ",
         alignLeft("update", updateWidth), "  | ",
         alignLeft("latest", latestWidth)
    
    # divider
    echo repeat("⎺", nameWidth + versionWidth + updateWidth + latestWidth + 12)

    # rows
    for recipe in checkResults:
        if outdatedOnly and recipe.apiError == "" and canCompareVersions(recipe.version, recipe.mversion) and not isNewerVersion(recipe.version, recipe.mversion):
            continue
        # start of testing only!
        if recipe.apiError == "" and recipe.mversion.len > 0:
          if not canCompareVersions(recipe.version, recipe.mversion):
            echo "[DEBUG] ", recipe.name,
                 ": current='", recipe.version,
                 "', latest='", recipe.mversion, "'"
        # end of testing only!
        let comparisonUnknown =
            recipe.apiError == "" and
            recipe.mversion.len > 0 and
            not canCompareVersions(recipe.version, recipe.mversion)

        let latest =
            if recipe.apiError != "":
                "Error: " & recipe.apiError
            elif comparisonUnknown:
                recipe.mversion & " (version comparison unknown)"
            elif recipe.isPreRelease:
                recipe.mversion & " (pre-release)"
            else:
                recipe.mversion

        let updateAvailable =
            recipe.apiError == "" and
            recipe.mversion.len > 0 and
            not comparisonUnknown and
            canCompareVersions(recipe.version, recipe.mversion) and
            isNewerVersion(recipe.version, recipe.mversion)
        
        let updateMark = if updateAvailable: "X" else: ""
        
        stdout.write(
            alignLeft(recipe.name, nameWidth), "  | ",
            alignLeft(recipe.version, versionWidth), "  | "
        )
        
        if updateAvailable:
           let leftPad = (updateWidth - updateMark.len) div 2
           let centeredMark = repeat(" ", leftPad) & updateMark &
               repeat(" ", updateWidth - leftPad - updateMark.len)
           
           stdout.styledWrite(fgGreen, centeredMark, resetStyle)
        else:
            stdout.write(align(updateMark, updateWidth))
        
        stdout.write("  | ")
        
        if recipe.apiError != "":
            stdout.styledWrite(fgDefault, latest)
        elif comparisonUnknown:
            stdout.styledWrite(fgYellow, latest)
        elif updateAvailable:
            stdout.styledWrite(fgRed, latest)
        else:
            stdout.styledWrite(fgDefault, latest)
        
        stdout.write("\n")
        


# check release-monitoring.org for the stable_versions(0) > latest_version > version(0)
proc fetchVersions( client: AsyncHttpClient, apiUrl: string): Future[tuple[data: JsonNode, apiError: string]] {.async.} =
    for attempt in 0 .. 2:
        try:
            let response = await client.getContent(apiUrl)
            return (parseJson(response), "")

        except HttpRequestError as e:
            let errorMessage = e.msg.splitLines()[0]

            if attempt < 2 and (
                "502" in e.msg or
                "503" in e.msg or
                "504" in e.msg or
                "429" in e.msg
            ):
                await sleepAsync(500 * (attempt + 1))
                continue

            return (newJNull(), errorMessage)

        except ProtocolError as e:
            if attempt < 2:
                await sleepAsync(500 * (attempt + 1))
                continue

            return (
                newJNull(),
                "Protocol error: " & e.msg.splitLines()[0]
            )

        except JsonParsingError as e:
            return (newJNull(), "Invalid JSON: " & e.msg)

    return (newJNull(), "Request failed after retries")



proc printProgress(completedRecipes, totalRecipes: int) =
    if totalRecipes == 0:
        return

    let progress = (completedRecipes * 20) div totalRecipes

    stdout.write("\r[")
    for i in 0 ..< 20:
        if i < progress:
            stdout.write("■")
        else:
            stdout.write("□")

    stdout.write("] ", $completedRecipes, "/", $totalRecipes)
    stdout.flushFile()
    

proc compareVersion(mode: string = "", recipeDirectory: string = "", outdatedOnly: bool = false): Future[void] {.async.} =
    let currentConfig = readConfig()

    let directory =
        if recipeDirectory != "":
            recipeDirectory
        else:
            currentConfig.recipeDirectory

    let recipesDb = crawlRecipes(directory)

    var monitoredRecipes: seq[RecipeInfo] = @[]

    if mode == "all" or recipeDirectory != "":
        for recipe in recipesDb:
            if recipe.monitoring and recipe.releaseId > 0:
                monitoredRecipes.add(recipe)
    else:
        for configuredRecipe in currentConfig.recipes:
            var found = false

            for recipe in recipesDb:
                if recipe.name == configuredRecipe.name:
                    found = true

                    if not recipe.monitoring:
                        echo configuredRecipe.name, ": no monitoring.yaml found"
                    elif recipe.releaseId <= 0:
                        echo configuredRecipe.name, ": release monitoring ID not configured"
                    else:
                        monitoredRecipes.add(recipe)

                    break

            if not found:
                echo configuredRecipe.name, ": no package found"

    # Store all fetched recipe information.
    var checkResults = newSeq[RecipeInfo](monitoredRecipes.len)

    const workerCount = 30
    var nextIndex = 0

    # Progress bar variables.
    var completedRecipes = 0
    let totalRecipes = monitoredRecipes.len
    echo ""
    if totalRecipes == 0:
        echo "No packages to check."
        return

    proc worker(): Future[void] {.async.} =
        let client = newAsyncHttpClient()
        try:
            while nextIndex < monitoredRecipes.len:
                let index = nextIndex
                inc nextIndex

                let recipe = monitoredRecipes[index]
                let apiUrl = ReleaseMonitoringApi & $recipe.releaseId

                let result = await fetchVersions(client, apiUrl)
                let data = result.data  
                if data.isNil or data.kind == JNull:
                    var checkResult = recipe
                    checkResult.apiError = result.apiError
                    checkResults[index] = checkResult

                    inc completedRecipes
                    printProgress(completedRecipes, totalRecipes)
                    continue

                let latest = getLatestVersion(data)
                var checkResult = recipe
                
                if latest.mversion.len == 0:
                    checkResult.apiError = "No version found in API response"
                else:
                    checkResult.mversion = latest.mversion
                    checkResult.isPreRelease = latest.isPreRelease
                
                checkResults[index] = checkResult

                inc completedRecipes
                printProgress(completedRecipes, totalRecipes)
        finally:
            client.close()

    var workers: seq[Future[void]] = @[]

    for i in 0 ..< min(workerCount, monitoredRecipes.len):
        workers.add(worker())

    await all(workers)

    # Move to a new line before printing the table.
    echo ""
    echo ""

    printVersionTable(checkResults, outdatedOnly = outdatedOnly)
    let updateCount = checkResults.countIt(
        it.apiError.len == 0 and
        it.mversion.len > 0 and
        isNewerVersion(it.version, it.mversion)
    )
    
    echo fmt "\nUpdates available: {updateCount}\n"
    
proc updateDir(recipeDirectory: string) =
    # read current config
    var currentConfig = readConfig()
       
    let configStream = newFileStream(configPath, fmWrite)
    if configStream.isNil:
        quit("Failed to access config", 1)
    else:
        configStream.write(
            toolHeader.splitLines()
                .mapIt("# " & it)
                .join("\n") & "\n"
        )
        currentConfig.recipeDirectory = recipeDirectory
        Dumper().dump(currentConfig, configStream)
        configStream.close()
        echo "Updated package directory: " & recipeDirectory


# Update the current package list (add/delete)
type
    RecipeAction = enum
        add, del

proc updateRecipes(recipeNames: seq[string], action: RecipeAction) =
    # read current config
    var currentConfig = readConfig()
    for recipeName in recipeNames:
        case action
        of add:
            # Add recipeName to currentConfig.recipes
            var alreadyTracked = false        
            for recipe in currentConfig.recipes:
                if recipe.name == recipeName:
                    alreadyTracked = true
                    break
            if alreadyTracked:
                echo recipeName & " is already tracked."
            else:
                currentConfig.recipes.add(Recipe(name: recipeName))
                echo "Added " & recipeName
        of del:
            # Remove recipeName from currentConfig.recipes
            var found = false        
            for d in countdown(currentConfig.recipes.high, 0):
                if currentConfig.recipes[d].name == recipeName:
                    currentConfig.recipes.delete(d)
                    found = true

            if found:
                echo "Deleted " & recipeName
            else:
                echo recipeName & " is not tracked, nothing to delete."
    

    let configStream = newFileStream(configPath, fmWrite)
    if configStream.isNil:
        echo "Failed to access config"
    else:
        configStream.write(
            toolHeader.splitLines()
                .mapIt("# " & it)
                .join("\n") & "\n"
        )
        Dumper().dump(currentConfig, configStream)
        configStream.close()
        

# proc testVersionParsing() =
#     echo "Testing parseVersionParts:"
# 
#     let testVersions = [
#         "16.2.0",
#         "v16.2.0",
#         "releases/gcc-16.2.0",
#         "unknown",
#         "16..2",
#         "desktop-v2026.10.0",
#         "boost-1.92.0",
#         "epoch-1.11.0",
#         "edk2-stable202608",
#         "noto-monthly-release-2026.10.01",
#         "NotoSansV2.001",
#         "LibVNCServer-0.9.15",
#         "0.7.91~git20230705.8eabf68",
#         "+kde.bebdfd54",
#         "5.15.19",
#         "VERSION_0.25"
#     ]
# 
#     for version in testVersions:
#         let parts = parseVersionParts(version)
#         if parts.isSome:
#             echo version, " -> ", parts.get
#         else:
#             echo version, " -> cannot parse"
# 
#     echo "\nTesting isNewerVersion:"
# 
#     echo "16.1.0 -> 16.2.0: ", isNewerVersion("16.1.0", "16.2.0")
#     echo "16.2.0 -> 16.2.0: ", isNewerVersion("16.2.0", "16.2.0")
#     echo "16.3.0 -> 16.2.0: ", isNewerVersion("16.3.0", "16.2.0")
#     echo "unknown -> 16.2.0: ", isNewerVersion("unknown", "16.2.0")


# Writes a fresh new config.yaml
proc writeConfig(recipeDir: string) =
    echo "\nConfig not found. Creating new config at: " & configPath   
    let configDir = parentDir(configPath)
    createDir(configDir)
    var config = newFileStream(configPath, fmWrite)
    if config.isNil:
            quit("Error: Could not create config.yaml", 1)
    else:
        config.write(fmt"""
{toolHeader.splitLines().mapIt("# " & it).join("\n")}
recipeDirectory: "{recipeDir}"
recipes:
    - name: nano
    - name: micro
    - name: bat
  
""")
        config.close()
        echo "New config successfully created!"

# error message for wrong commands
proc unknownCommand() {.noreturn.} =
    echo ""
    styledEcho styleBright, fgYellow, "Unknown command. Type\n\naspt help\n\nfor further instructions", resetStyle
    echo ""
    quit(1)

# check for command flags
if paramCount() != 0:
    if paramStr(1) == "init":
        if paramCount() < 2:
            echo "\nDirectory empty! Please try again and use:\n"
            echo "  aspt init <package-directory>\n"
            quit(1)

        elif not dirExists(paramStr(2)):
            echo "\nThis is not a valid directory! Please try again\n"
            quit(1)

        else:
            let recipeDir = paramStr(2)

            if fileExists(configPath):
                echo "\nConfig found: " & configPath
                updateDir(recipeDir)
            else:
                writeConfig(recipeDir)
                echo "New package directory set to: " & recipeDir

        quit(0)
    # help page
    elif paramStr(1) == "help":
        echo fmt """
    {toolHeader}
    Commands & Usage:

    aspt init <package-directory>       |  Updates the package directory and creates a new config if necessary
                                           Does not overwrite existing configs

    aspt check                          |  Checks your tracked packages across your defined package directory
    aspt check outdated                 |  Same as <check>, but filtered for outdated only
                                           

    aspt check /path/to/check           |  Checks all packages in a given path
    aspt check outdated /path/to/check  |  Same as <check /path/to/check>, but filtered for outdated only
                                           

    aspt check all                      |  Checks all packages in your defined <package-directory>
    aspt check all outdated             |  Same as <all>, but filtered for outdated only
                                           
    aspt pkg add <pkg-xyz1,xyz2,...>    |  Adds one or more packages to the tracked list
    aspt pkg del <pkgxyz3,name4,...>    |  Deletes one or more packages from the tracked list

    aspt help                           |  Show this help text
"""
        quit(0)
    elif paramStr(1) == "pkg":
        if paramCount() < 2:
            unknownCommand()

        elif paramStr(2) == "add":
            if paramCount() < 3:
                echo "Usage: aspt pkg add <package1,package2,...>"
                quit(1)

            let packageInput = commandLineParams()[2 .. ^1].join(" ")
            let recipeUpd = packageInput.split(',').mapIt(it.strip()).filterIt(it.len > 0)
            
            if recipeUpd.len == 0:
                echo "Please provide at least one package name."
                quit(1)
            
            updateRecipes(recipeUpd, add)
            quit(0)

        elif paramStr(2) == "del":
            if paramCount() < 3:
                echo "Usage: aspt pkg del <package1,package2,...>"
                quit(1)

            let packageInput = commandLineParams()[2 .. ^1].join(" ")
            let recipeUpd = packageInput.split(',').mapIt(it.strip()).filterIt(it.len > 0)
            
            if recipeUpd.len == 0:
                echo "Please provide at least one package name."
                quit(1)
            
            updateRecipes(recipeUpd, del)
            quit(0)

        else:
            unknownCommand()
    elif paramStr(1) == "check":
        if paramCount() == 1:
            waitFor compareVersion()

        elif paramStr(2) == "outdated":
            if paramCount() == 2:
                waitFor compareVersion(outdatedOnly = true)
            elif paramCount() == 3:
                let directory = paramStr(3)

                if not dirExists(directory):
                    echo "Directory does not exist: ", directory
                    quit(1)

                waitFor compareVersion(
                    recipeDirectory = directory,
                    outdatedOnly = true
                )
            else:
                unknownCommand()

        elif paramStr(2) == "all":
            if paramCount() == 2:
                waitFor compareVersion(mode = "all")
            elif paramCount() == 3 and paramStr(3) == "outdated":
                waitFor compareVersion(mode = "all", outdatedOnly = true)
            else:
                unknownCommand()

        elif paramCount() == 2:
            let directory = paramStr(2)

            if not dirExists(directory):
                echo "Directory does not exist: ", directory
                quit(1)

            waitFor compareVersion(recipeDirectory = directory)

        else:
            unknownCommand()

        quit(0)
    # elif paramStr(1) == "test-version":
    #     testVersionParsing()
    #     quit(0)
    else:
        unknownCommand()
else:
    if not fileExists(configPath):
        echo "\nConfig not found. To initialize aspt and create a config run:\n\naspt init <package-directory>\n\nBye..."
        quit(1)

    waitFor compareVersion(outdatedOnly = true)
    quit(0)

