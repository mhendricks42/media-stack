#!/usr/bin/env bash
set -euo pipefail

readonly SONARR_URL='http://localhost:8989'
readonly RADARR_URL='http://localhost:7878'
readonly PROWLARR_URL='http://localhost:9696'
readonly QBIT_URL='http://localhost:8080'
readonly SAB_URL='http://localhost:8081'
readonly JELLYFIN_URL='http://localhost:8096'
readonly SEERR_URL='http://localhost:5055'
readonly JELLYFIN_CLIENT='MediaBrowser Client="media-stack", Device="bootstrap", DeviceId="media-stack-bootstrap", Version="1.0"'

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

require_environment() {
  local missing=()
  local name
  local qbit_user="${QBIT_USER:-admin}"
  for name in \
    QBIT_PASS SABNZBD_USER SABNZBD_PASS \
    SONARR_USER SONARR_PASS RADARR_USER RADARR_PASS \
    PROWLARR_USER PROWLARR_PASS BAZARR_USER BAZARR_PASS \
    JELLYFIN_USER JELLYFIN_PASS SEERR_EMAIL
  do
    [[ -n "${!name:-}" ]] || missing+=("$name")
  done
  ((${#missing[@]} == 0)) || fail "Missing bootstrap environment variable(s): ${missing[*]}"
  ((${#QBIT_PASS} >= 6)) || fail "QBIT_PASS must be at least 6 characters."
  ((${#SABNZBD_PASS} >= 6)) || fail "SABNZBD_PASS must be at least 6 characters."
  ((${#qbit_user} >= 3)) || fail "QBIT_USER must be at least 3 characters."
  [[ "$qbit_user" != *:* ]] || fail "QBIT_USER cannot contain a colon."
}

get_env_file_value() {
  local name="$1"
  [[ -f .env ]] || return
  sed -n "s/^${name}=//p" .env | head -n 1 | tr -d '\r' | sed -E "s/^[\"']|[\"']$//g"
}

get_api_key() {
  local path="$1"
  [[ -f "$path" ]] || fail "Missing config file: $path. Start the stack once before bootstrap."
  local value
  value="$(sed -n 's:.*<ApiKey>\([^<]*\)</ApiKey>.*:\1:p' "$path" | head -n 1)"
  [[ -n "$value" ]] || fail "No ApiKey found in $path."
  printf '%s' "$value"
}

redact_sensitive() {
  sed -E \
    -e 's/("(password|pass|api[Kk]ey|token|secret)"[[:space:]]*:[[:space:]]*")[^"]+/\1<redacted>/gI' \
    -e 's/((password|pass|api[Kk]ey|token|secret)=)[^&\\"[:space:]]+/\1<redacted>/gI'
}

api() {
  local method="$1"
  local url="$2"
  local api_key="$3"
  local body="${4:-}"
  local response
  response="$(mktemp)"
  local status
  if [[ -n "$body" ]]; then
    if ! status="$(curl -sS -o "$response" -w '%{http_code}' -X "$method" \
      -H "X-Api-Key: $api_key" -H 'Content-Type: application/json; charset=utf-8' \
      --data-binary "$body" "$url")"; then
      rm -f "$response"
      fail "API $method $url could not be reached."
    fi
  else
    if ! status="$(curl -sS -o "$response" -w '%{http_code}' -X "$method" \
      -H "X-Api-Key: $api_key" "$url")"; then
      rm -f "$response"
      fail "API $method $url could not be reached."
    fi
  fi
  if [[ "$status" -lt 200 || "$status" -ge 300 ]]; then
    redact_sensitive <"$response" >&2
    rm -f "$response"
    fail "API $method $url failed with status $status."
  fi
  cat "$response"
  rm -f "$response"
}

wait_url() {
  local url="$1"
  local seconds="$2"
  local attempt
  for ((attempt = 0; attempt < seconds; attempt++)); do
    if curl -s -o /dev/null --max-time 5 "$url"; then
      return
    fi
    sleep 1
  done
  fail "$url did not become ready within $seconds seconds."
}

check_seerr_config_write_access() {
  if ! docker compose run --rm --no-deps --entrypoint sh seerr -c \
    'touch /app/config/.media-stack-write-test && rm -f /app/config/.media-stack-write-test'; then
    fail "Seerr cannot write to config/seerr as UID/GID 1000:1000. Remove inherited deny ACLs, restore ownership, and rerun bootstrap: sudo setfacl -Rb config/seerr; sudo chown -R 1000:1000 config/seerr; sudo chmod -R u+rwX,g+rX,o-rwx config/seerr"
  fi
}

configure_qbittorrent() {
  local config='config/qbittorrent/qBittorrent/qBittorrent.conf'
  [[ -f "$config" ]] || fail "Missing qBittorrent config: $config"
  export QBIT_CONFIG_PATH="$config"
  export QBIT_USER="${QBIT_USER:-admin}"
  docker compose stop qbittorrent >/dev/null
  if ! python3 <<'PY'
import base64
import hashlib
import os
from pathlib import Path

path = Path(os.environ["QBIT_CONFIG_PATH"])
content = path.read_text(encoding="utf-8")

def set_value(text, key, value, section="Preferences"):
    lines = text.splitlines()
    assignment = f"{key}={value}"
    for index, line in enumerate(lines):
        if line.startswith(f"{key}="):
            lines[index] = assignment
            return "\n".join(lines) + "\n"
    header = f"[{section}]"
    try:
        index = lines.index(header)
    except ValueError as error:
        raise SystemExit(f"qBittorrent config is missing {header}.") from error
    lines.insert(index + 1, assignment)
    return "\n".join(lines) + "\n"

password = os.environ["QBIT_PASS"]
salt = os.urandom(16)
digest = hashlib.pbkdf2_hmac("sha512", password.encode(), salt, 100000, 64)
password_hash = f"@ByteArray({base64.b64encode(salt).decode()}:{base64.b64encode(digest).decode()})"

values = [
    ("Session\\DefaultSavePath", "/data/torrents", "BitTorrent"),
    ("Session\\TempPath", "/data/torrents/incomplete/", "BitTorrent"),
    ("Session\\GlobalMaxRatio", "1", "BitTorrent"),
    ("Session\\GlobalMaxSeedingMinutes", "1440", "BitTorrent"),
    ("Session\\GlobalMaxInactiveSeedingMinutes", "1440", "BitTorrent"),
    ("Session\\ShareLimitAction", "Stop", "BitTorrent"),
    ("Downloads\\SavePath", "/data/torrents", "Preferences"),
    ("Downloads\\TempPath", "/data/torrents/incomplete/", "Preferences"),
    ("WebUI\\Username", os.environ["QBIT_USER"], "Preferences"),
    ("WebUI\\Password_PBKDF2", f'"{password_hash}"', "Preferences"),
]
for key, value, section in values:
    content = set_value(content, key, value, section)
path.write_text(content, encoding="utf-8")
PY
  then
    docker compose up -d qbittorrent >/dev/null
    fail "Could not update qBittorrent configuration."
  fi
  docker compose up -d qbittorrent >/dev/null
  wait_url "$QBIT_URL" 60
  local result status
  result="$(mktemp)"
  status="$(curl -sS --max-time 10 -o "$result" -w '%{http_code}' -X POST \
    --data-urlencode "username=$QBIT_USER" --data-urlencode "password=$QBIT_PASS" \
    "$QBIT_URL/api/v2/auth/login")"
  if [[ "$status" -lt 200 || "$status" -ge 300 ]] ||
    [[ -s "$result" && "$(<"$result")" != 'Ok.' ]]; then
    rm -f "$result"
    fail "qBittorrent rejected QBIT_USER/QBIT_PASS (HTTP $status)."
  fi
  rm -f "$result"
  echo "qBittorrent credentials, paths, and seeding limits configured."
}

configure_sabnzbd() {
  local config='config/sabnzbd/sabnzbd.ini'
  [[ -f "$config" ]] || fail "Missing SABnzbd config: $config"
  export SAB_CONFIG_PATH="$config"
  docker compose stop sabnzbd >/dev/null
  if ! python3 <<'PY'
import os
import re
import json
from pathlib import Path

path = Path(os.environ["SAB_CONFIG_PATH"])
content = path.read_text(encoding="utf-8")

def set_section_value(text, section, key, value):
    section_match = re.search(rf"(?m)^\[{re.escape(section)}\]\r?$", text)
    if not section_match:
        text = text.rstrip() + f"\n[{section}]\n"
        section_match = re.search(rf"(?m)^\[{re.escape(section)}\]\r?$", text)
    end = re.search(r"(?m)^\[", text[section_match.end() + 1:])
    block_end = section_match.end() + 1 + (end.start() if end else len(text))
    block = text[section_match.end():block_end]
    replacement = f"{key} = {value}"
    if re.search(rf"(?m)^{re.escape(key)}\s*=.*$", block):
        block = re.sub(rf"(?m)^{re.escape(key)}\s*=.*$", replacement, block)
    else:
        block = block.rstrip() + f"\n{replacement}\n"
    return text[:section_match.end()] + block + text[block_end:]

def append_section_list_value(text, section, key, value):
    section_pattern = rf"(?ms)(^\[{re.escape(section)}\]\r?\n)(.*?)(?=^\[|\Z)"
    section_match = re.search(section_pattern, text)
    if not section_match:
        text = set_section_value(text, section, key, value)
        return text
    key_match = re.search(rf"(?m)^{re.escape(key)}\s*=\s*(.*)$", section_match.group(2))
    values = []
    if key_match:
        values = [
            item.strip().strip("\"'")
            for item in key_match.group(1).split(",")
            if item.strip().strip("\"'")
        ]
    if value.casefold() not in {item.casefold() for item in values}:
        values.append(value)
    return set_section_value(text, section, key, ", ".join(values))

for key, value in {
    "host": "0.0.0.0",
    "port": "8080",
    "username": os.environ["SABNZBD_USER"],
    "password": os.environ["SABNZBD_PASS"],
    "download_dir": "/data/usenet/incomplete",
    "complete_dir": "/data/usenet/complete",
}.items():
    content = set_section_value(content, "misc", key, value)
content = append_section_list_value(content, "misc", "host_whitelist", "sabnzbd")

def set_nested_section(text, parent, name, values):
    if not re.search(rf"(?m)^\[{re.escape(parent)}\]\r?$", text):
        text = text.rstrip() + f"\n[{parent}]\n"
    pattern = rf"(?ms)(^\[\[{re.escape(name)}\]\]\r?\n)(.*?)(?=^\[\[|^\[|\Z)"
    body = "\n".join(f"{key} = {value}" for key, value in values.items()) + "\n"
    if re.search(pattern, text):
        return re.sub(pattern, lambda match: match.group(1) + body, text, count=1)
    parent_pattern = rf"(?ms)(^\[{re.escape(parent)}\]\r?\n)(.*?)(?=^\[|\Z)"
    return re.sub(parent_pattern, lambda match: match.group(1) + match.group(2).rstrip() + f"\n[[{name}]]\n{body}", text, count=1)

def ini_value(value):
    if isinstance(value, bool):
        return "1" if value else "0"
    text = str(value)
    if re.fullmatch(r"[0-9]+", text):
        return text
    if re.search(r'''[#;=\[\]"'\s]''', text):
        return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'
    return text

content = set_nested_section(content, "categories", "tv", {
    "priority": "0", "pp": "3", "name": "tv", "script": "None", "dir": "tv", "newzbin": ""
})
content = set_nested_section(content, "categories", "movies", {
    "priority": "0", "pp": "3", "name": "movies", "script": "None", "dir": "movies", "newzbin": ""
})

servers_json = os.environ.get("SAB_SERVERS_JSON")
if servers_json:
    parsed = json.loads(servers_json)
    servers = parsed.get("servers", []) if isinstance(parsed, dict) else parsed
else:
    servers = []

for prefix, priority, optional in (("SAB_SERVER", 0, 0), ("SAB_BACKUP_SERVER", 1, 1)):
    host = os.environ.get(f"{prefix}_HOST", "")
    if not host:
        continue
    username = os.environ.get(f"{prefix}_USER") or os.environ.get(f"{prefix}_USERNAME", "")
    password = os.environ.get(f"{prefix}_PASS") or os.environ.get(f"{prefix}_PASSWORD", "")
    if not username or not password:
        raise SystemExit(f"{prefix}_HOST requires {prefix}_USER and {prefix}_PASS.")
    name = os.environ.get(f"{prefix}_NAME", host)
    servers.append({
        "name": name,
        "displayName": os.environ.get(f"{prefix}_DISPLAY_NAME", name),
        "host": host,
        "username": username,
        "password": password,
        "port": int(os.environ.get(f"{prefix}_PORT", "563")),
        "connections": int(os.environ.get(f"{prefix}_CONNECTIONS", "20")),
        "ssl": os.environ.get(f"{prefix}_SSL", "true").lower() in ("1", "true", "yes", "on"),
        "sslVerify": int(os.environ.get(f"{prefix}_SSL_VERIFY", "2")),
        "enable": os.environ.get(f"{prefix}_ENABLE", "true").lower() in ("1", "true", "yes", "on"),
        "required": os.environ.get(f"{prefix}_REQUIRED", "0").lower() in ("1", "true", "yes", "on"),
        "optional": os.environ.get(f"{prefix}_OPTIONAL", str(optional)).lower() in ("1", "true", "yes", "on"),
        "retention": int(os.environ.get(f"{prefix}_RETENTION", "0")),
        "priority": int(os.environ.get(f"{prefix}_PRIORITY", str(priority))),
    })

for server in servers:
    for required in ("host", "username", "password"):
        if not server.get(required):
            raise SystemExit(f"Each SAB server entry requires {required}.")
    name = server.get("name", server["host"])
    values = {
        "name": name,
        "displayname": server.get("displayName", name),
        "host": server["host"],
        "port": server.get("port", 563),
        "timeout": 120,
        "username": server["username"],
        "password": server["password"],
        "connections": server.get("connections", 20),
        "ssl": server.get("ssl", True),
        "ssl_verify": server.get("sslVerify", 2),
        "enable": server.get("enable", True),
        "required": server.get("required", False),
        "optional": server.get("optional", False),
        "retention": server.get("retention", 0),
        "send_group": 0,
        "priority": server.get("priority", 0),
    }
    content = set_nested_section(content, "servers", name, {key: ini_value(value) for key, value in values.items()})

path.write_text(content, encoding="utf-8")
PY
  then
    docker compose up -d sabnzbd >/dev/null
    fail "Could not update SABnzbd configuration."
  fi
  docker compose up -d sabnzbd >/dev/null
  wait_url "$SAB_URL" 60
  echo "SABnzbd credentials, paths, categories, and provider servers configured."
}

configure_arr_auth() {
  local name="$1" url="$2" key="$3" user="$4" password="$5" version="${6:-v3}"
  ((${#password} >= 6)) || fail "$name password must be at least 6 characters."
  local config
  config="$(api GET "$url/api/$version/config/host" "$key")"
  config="$(jq --arg username "$user" --arg password "$password" '
    .authenticationMethod = "Forms" |
    .authenticationRequired = "Enabled" |
    .username = $username |
    .password = $password |
    .passwordConfirmation = $password
  ' <<<"$config")"
  api PUT "$url/api/$version/config/host/$(jq -r '.id' <<<"$config")" "$key" "$config" >/dev/null
  if [[ "$name" == 'Prowlarr' ]]; then
    docker compose restart prowlarr >/dev/null
    wait_url "$url" 120
    local status headers location
    headers="$(mktemp)"
    status="$(curl -sS -o /dev/null -D "$headers" -w '%{http_code}' -X POST \
      --data-urlencode "username=$user" --data-urlencode "password=$password" "$url/login")"
    location="$(awk 'tolower($1) == "location:" {gsub(/\r/, "", $2); print $2; exit}' "$headers")"
    rm -f "$headers"
    [[ "$status" == 302 && "$location" == / ]] ||
      fail "Prowlarr rejected PROWLARR_USER/PROWLARR_PASS."
  fi
  echo "$name Forms login configured."
}

configure_bazarr_auth() {
  local config='config/bazarr/config/config.yaml'
  [[ -f "$config" ]] || fail "Missing Bazarr config: $config"
  export BAZARR_CONFIG_PATH="$config"
  python3 <<'PY'
import hashlib
import json
import os
import re
from pathlib import Path

path = Path(os.environ["BAZARR_CONFIG_PATH"])
content = path.read_text(encoding="utf-8")
values = {
    "type": "form",
    "username": json.dumps(os.environ["BAZARR_USER"]),
    "password": json.dumps(hashlib.md5(os.environ["BAZARR_PASS"].encode(), usedforsecurity=False).hexdigest()),
}
for key, value in values.items():
    pattern = rf"(?ms)(^auth:\r?\n.*?^  {re.escape(key)}:)[^\r\n]*"
    if not re.search(pattern, content):
        raise SystemExit(f"Bazarr config is missing auth.{key}.")
    content = re.sub(pattern, rf"\g<1> {value}", content, count=1)
path.write_text(content, encoding="utf-8")
PY
  docker compose restart bazarr >/dev/null
  echo "Bazarr Forms login configured."
}

jellyfin_authenticate() {
  curl -sS -f -X POST "$JELLYFIN_URL/Users/AuthenticateByName" \
    -H "Authorization: $JELLYFIN_CLIENT" -H 'Content-Type: application/json' \
    --data-binary "$(jq -nc --arg user "$JELLYFIN_USER" --arg pass "$JELLYFIN_PASS" '{Username:$user,Pw:$pass}')"
}

configure_jellyfin() {
  local session
  if ! session="$(jellyfin_authenticate 2>/dev/null)"; then
    local startup_status
    startup_status="$(curl -s -o /dev/null -w '%{http_code}' "$JELLYFIN_URL/Startup/User" \
      -H "Authorization: $JELLYFIN_CLIENT")"
    if [[ "$startup_status" == 401 || "$startup_status" == 403 ]]; then
      fail "Jellyfin is already initialized and rejected JELLYFIN_USER/JELLYFIN_PASS. Supply the existing administrator credentials or reset that account before rerunning bootstrap."
    fi
    [[ "$startup_status" -ge 200 && "$startup_status" -lt 300 ]] ||
      fail "Jellyfin first-run endpoint failed with HTTP $startup_status."
    curl -sS -f -X POST "$JELLYFIN_URL/Startup/User" \
      -H "Authorization: $JELLYFIN_CLIENT" -H 'Content-Type: application/json' \
      --data-binary "$(jq -nc --arg user "$JELLYFIN_USER" --arg pass "$JELLYFIN_PASS" '{Name:$user,Password:$pass}')" >/dev/null
    curl -sS -f -X POST "$JELLYFIN_URL/Startup/Complete" \
      -H "Authorization: $JELLYFIN_CLIENT" -H 'Content-Type: application/json' --data-binary '{}' >/dev/null
    local attempt
    for ((attempt = 0; attempt < 90; attempt++)); do
      if session="$(jellyfin_authenticate 2>/dev/null)"; then
        break
      fi
      sleep 1
    done
    [[ -n "${session:-}" ]] || fail "Jellyfin did not accept JELLYFIN_USER/JELLYFIN_PASS after initialization."
  fi

  local token auth server_name config libraries name type path query body
  token="$(jq -r '.AccessToken' <<<"$session")"
  [[ -n "$token" && "$token" != null ]] || fail "Jellyfin authentication returned no token."
  auth="MediaBrowser Token=\"$token\", Client=\"media-stack\", Device=\"bootstrap\", DeviceId=\"media-stack-bootstrap\", Version=\"1.0\""
  server_name="$(get_env_file_value JELLYFIN_SERVER_NAME)"
  server_name="${server_name:-Media Stack}"
  config="$(curl -sS -f "$JELLYFIN_URL/System/Configuration" -H "Authorization: $auth")"
  curl -sS -f -X POST "$JELLYFIN_URL/System/Configuration" \
    -H "Authorization: $auth" -H 'Content-Type: application/json' \
    --data-binary "$(jq --arg name "$server_name" '.ServerName=$name' <<<"$config")" >/dev/null

  for spec in 'Movies|movies|/data/media/movies' 'Shows|tvshows|/data/media/tv'; do
    IFS='|' read -r name type path <<<"$spec"
    libraries="$(curl -sS -f "$JELLYFIN_URL/Library/VirtualFolders" -H "Authorization: $auth")"
    if jq -e --arg name "$name" --arg path "$path" '.[] | select(.Name==$name) | .Locations[]? | select(.==$path)' <<<"$libraries" >/dev/null; then
      echo "Jellyfin library verified: $name -> $path"
      continue
    fi
    query="name=$(jq -rn --arg value "$name" '$value|@uri')"
    if jq -e --arg name "$name" '.[] | select(.Name==$name)' <<<"$libraries" >/dev/null; then
      curl -sS -f -X POST "$JELLYFIN_URL/Library/VirtualFolders/Paths?$query" \
        -H "Authorization: $auth" -H 'Content-Type: application/json' \
        --data-binary "$(jq -nc --arg name "$name" --arg path "$path" '{Name:$name,Path:$path}')" >/dev/null
    else
      body="$(jq -nc --arg path "$path" --arg type "$type" '{
        Enabled:true,EnablePhotos:true,EnableRealtimeMonitor:true,EnableInternetProviders:true,
        EnableLUFSScan:true,EnableChapterImageExtraction:false,
        ExtractChapterImagesDuringLibraryScan:false,EnableTrickplayImageExtraction:false,
        ExtractTrickplayImagesDuringLibraryScan:false,PathInfos:[{Path:$path}],
        SaveLocalMetadata:false,EnableAutomaticSeriesGrouping:false,EnableEmbeddedTitles:false,
        EnableEmbeddedExtrasTitles:false,EnableEmbeddedEpisodeInfos:false,
        AutomaticRefreshIntervalDays:0,PreferredMetadataLanguage:"",MetadataCountryCode:"",
        SeasonZeroDisplayName:"Specials",MetadataSavers:[],
        DisabledLocalMetadataReaders:[],LocalMetadataReaderOrder:["Nfo"],
        DisabledSubtitleFetchers:[],SubtitleFetcherOrder:[],SubtitleDownloadLanguages:[],
        DisabledMediaSegmentProviders:[],MediaSegmentProviderOrder:[],
        SkipSubtitlesIfEmbeddedSubtitlesPresent:false,SkipSubtitlesIfAudioTrackMatches:false,
        RequirePerfectSubtitleMatch:true,SaveSubtitlesWithMedia:true,
        DisabledLyricFetchers:[],LyricFetcherOrder:[],CustomTagDelimiters:["/","|",";","\\"],
        DelimiterWhitelist:[],AutomaticallyAddToCollection:false,AllowEmbeddedSubtitles:"AllowAll",
        TypeOptions:(if $type=="movies" then [{
          Type:"Movie",MetadataFetchers:["TheMovieDb","The Open Movie Database"],
          MetadataFetcherOrder:["TheMovieDb","The Open Movie Database"],
          ImageFetchers:["TheMovieDb","The Open Movie Database","Embedded Image Extractor","Screen Grabber"],
          ImageFetcherOrder:["TheMovieDb","The Open Movie Database","Embedded Image Extractor","Screen Grabber"],
          ImageOptions:[],SimilarItemProviders:["Local Genre/Tag"],
          SimilarItemProviderOrder:["TheMovieDb","Local Genre/Tag"]
        }] else [
          {Type:"Series",MetadataFetchers:["TheMovieDb","The Open Movie Database"],
           MetadataFetcherOrder:["TheMovieDb","The Open Movie Database"],ImageFetchers:["TheMovieDb"],
           ImageFetcherOrder:["TheMovieDb"],ImageOptions:[],SimilarItemProviders:["Local Genre/Tag"],
           SimilarItemProviderOrder:["TheMovieDb","Local Genre/Tag"]},
          {Type:"Season",MetadataFetchers:["TheMovieDb"],MetadataFetcherOrder:["TheMovieDb"],
           ImageFetchers:["TheMovieDb"],ImageFetcherOrder:["TheMovieDb"],ImageOptions:[],
           SimilarItemProviders:[],SimilarItemProviderOrder:[]},
          {Type:"Episode",MetadataFetchers:["TheMovieDb","The Open Movie Database"],
           MetadataFetcherOrder:["TheMovieDb","The Open Movie Database"],
           ImageFetchers:["TheMovieDb","The Open Movie Database","Embedded Image Extractor","Screen Grabber"],
           ImageFetcherOrder:["TheMovieDb","The Open Movie Database","Embedded Image Extractor","Screen Grabber"],
           ImageOptions:[],SimilarItemProviders:[],SimilarItemProviderOrder:[]}
        ] end)
      }')"
      curl -sS -f -X POST "$JELLYFIN_URL/Library/VirtualFolders?$query&collectionType=$type&refreshLibrary=false" \
        -H "Authorization: $auth" -H 'Content-Type: application/json' --data-binary "$body" >/dev/null
    fi
    echo "Jellyfin library configured: $name -> $path"
  done

  export JELLYFIN_LIVETV_PATH='config/jellyfin/livetv.xml'
  python3 <<'PY'
import os
import uuid
import xml.etree.ElementTree as ET
from pathlib import Path

path = Path(os.environ["JELLYFIN_LIVETV_PATH"])
if path.exists():
    tree = ET.parse(path)
    root = tree.getroot()
else:
    root = ET.Element("LiveTvOptions")
    tree = ET.ElementTree(root)

def child(parent, name, value=None):
    node = parent.find(name)
    if node is None:
        node = ET.SubElement(parent, name)
    if value is not None:
        node.text = value
    return node

tuner_url = "http://ersatztv:8409/iptv/channels.m3u"
guide_url = "http://ersatztv:8409/iptv/xmltv.xml"
tuners = child(root, "TunerHosts")
tuner = next((node for node in tuners.findall("TunerHostInfo") if child(node, "Url").text == tuner_url), None)
if tuner is None:
    tuner = ET.SubElement(tuners, "TunerHostInfo")
    child(tuner, "Id", uuid.uuid4().hex)
for name, value in {
    "Url": tuner_url, "Type": "m3u", "ImportFavoritesOnly": "false",
    "AllowHWTranscoding": "false", "AllowFmp4TranscodingContainer": "false",
    "AllowStreamSharing": "true", "FallbackMaxStreamingBitrate": "30000000",
    "EnableStreamLooping": "false", "TunerCount": "0", "IgnoreDts": "true",
    "ReadAtNativeFramerate": "true",
}.items():
    child(tuner, name, value)

providers = child(root, "ListingProviders")
provider = next((node for node in providers.findall("ListingsProviderInfo") if child(node, "Path").text == guide_url), None)
if provider is None:
    provider = ET.SubElement(providers, "ListingsProviderInfo")
    child(provider, "Id", uuid.uuid4().hex)
for name, value in {"Type": "xmltv", "Path": guide_url, "EnableAllTuners": "true"}.items():
    child(provider, name, value)

ET.indent(tree, space="  ")
path.parent.mkdir(parents=True, exist_ok=True)
tree.write(path, encoding="utf-8", xml_declaration=True)
PY
  docker compose restart jellyfin >/dev/null
  wait_url "$JELLYFIN_URL/System/Info/Public" 90
  echo "Jellyfin administrator and baseline configured."
}

initialize_seerr() {
  wait_url "$SEERR_URL/api/v1/status" 120
  if [[ "$(curl -sS -f "$SEERR_URL/api/v1/settings/public" | jq -r '.initialized')" != true ]]; then
    local cookies response status attempt
    cookies="$(mktemp)"
    response="$(mktemp)"
    local login_body
    login_body="$(jq -nc \
      --arg username "$JELLYFIN_USER" --arg password "$JELLYFIN_PASS" --arg email "$SEERR_EMAIL" \
      '{username:$username,password:$password,hostname:"jellyfin",port:8096,useSsl:false,urlBase:"",email:$email,serverType:2}')"

    status=000
    for ((attempt = 0; attempt < 15; attempt++)); do
      if ! status="$(curl -sS -o "$response" -c "$cookies" -w '%{http_code}' \
        -X POST "$SEERR_URL/api/v1/auth/jellyfin" \
        -H 'Content-Type: application/json' --data-binary "$login_body")"; then
        status=000
      fi
      [[ "$status" -ge 200 && "$status" -lt 300 ]] && break
      [[ "$status" =~ ^(000|404|502|503|504)$ ]] || break
      sleep 2
    done
    if [[ "$status" -lt 200 || "$status" -ge 300 ]]; then
      redact_sensitive <"$response" >&2
      rm -f "$cookies" "$response"
      fail "Seerr Jellyfin authentication failed with HTTP $status."
    fi

    status=000
    for ((attempt = 0; attempt < 15; attempt++)); do
      if ! status="$(curl -sS -o "$response" -b "$cookies" -w '%{http_code}' \
        -X POST "$SEERR_URL/api/v1/settings/initialize" \
        -H 'Content-Type: application/json' --data-binary '{}')"; then
        status=000
      fi
      [[ "$status" -ge 200 && "$status" -lt 300 ]] && break
      [[ "$status" =~ ^(000|404|502|503|504)$ ]] || break
      sleep 2
    done
    if [[ "$status" -lt 200 || "$status" -ge 300 ]]; then
      redact_sensitive <"$response" >&2
      rm -f "$cookies" "$response"
      fail "Seerr settings initialization failed with HTTP $status."
    fi

    rm -f "$cookies" "$response"
    echo "Seerr administrator initialized from Jellyfin credentials."
  else
    echo "Seerr administrator is already configured."
  fi
}

upsert_prowlarr_app() {
  local name="$1" implementation="$2" contract="$3" base_url="$4" api_key="$5"
  local fields payload existing id
  fields="$(jq -nc --arg base "$base_url" --arg key "$api_key" --arg impl "$implementation" '
    [
      {name:"prowlarrUrl",value:"http://prowlarr:9696"},
      {name:"baseUrl",value:$base},
      {name:"apiKey",value:$key},
      {name:"syncCategories",value:(if $impl=="Sonarr" then [5000] else [2000] end)},
      {name:"syncRejectBlocklistedTorrentHashesWhileGrabbing",value:true}
    ] + (if $impl=="Sonarr" then [
      {name:"animeSyncCategories",value:[5070]},
      {name:"syncAnimeStandardFormatSearch",value:false}
    ] else [] end)
  ')"
  payload="$(jq -nc --arg name "$name" --arg implementation "$implementation" --arg contract "$contract" --argjson fields "$fields" \
    '{enable:true,name:$name,implementationName:$implementation,implementation:$implementation,configContract:$contract,syncLevel:"fullSync",tags:[],fields:$fields}')"
  existing="$(api GET "$PROWLARR_URL/api/v1/applications" "$PROWLARR_API_KEY")"
  id="$(jq -r --arg name "$name" '.[] | select(.name==$name) | .id' <<<"$existing" | head -n 1)"
  if [[ -n "$id" ]]; then
    api PUT "$PROWLARR_URL/api/v1/applications/$id" "$PROWLARR_API_KEY" "$(jq --argjson id "$id" '.id=$id' <<<"$payload")" >/dev/null
  else
    api POST "$PROWLARR_URL/api/v1/applications" "$PROWLARR_API_KEY" "$payload" >/dev/null
  fi
  echo "Prowlarr app configured: $name"
}

configure_sonarr_baseline() {
  local config
  config="$(api GET "$SONARR_URL/api/v3/config/naming" "$SONARR_API_KEY")"
  config="$(jq '
    .renameEpisodes=true | .replaceIllegalCharacters=true | .colonReplacementFormat=4 |
    .customColonReplacementFormat="" | .multiEpisodeStyle=5 |
    .standardEpisodeFormat="{Series Title} - S{season:00}E{episode:00} - {Episode Title} {Quality Full}" |
    .dailyEpisodeFormat="{Series Title} - {Air-Date} - {Episode Title} {Quality Full}" |
    .animeEpisodeFormat="{Series CleanTitleWithoutYear} {(Series Year)} - S{season:00}E{episode:00} - {absolute:000} - {Episode CleanTitle:90} {[Custom Formats]}{[Quality Full]}{[Mediainfo AudioCodec}{ Mediainfo AudioChannels]}{MediaInfo AudioLanguages}{[MediaInfo VideoDynamicRangeType]}[{Mediainfo VideoCodec }{MediaInfo VideoBitDepth}bit]{-Release Group}" |
    .seriesFolderFormat="{Series CleanTitleWithoutYear} {(Series Year)}" |
    .seasonFolderFormat="Season {season:00}" | .specialsFolderFormat="Specials"
  ' <<<"$config")"
  api PUT "$SONARR_URL/api/v3/config/naming" "$SONARR_API_KEY" "$config" >/dev/null
  config="$(api GET "$SONARR_URL/api/v3/config/mediamanagement" "$SONARR_API_KEY")"
  config="$(jq '
    .autoUnmonitorPreviouslyDownloadedEpisodes=false | .recycleBin="" | .recycleBinCleanupDays=7 |
    .downloadPropersAndRepacks="preferAndUpgrade" | .createEmptySeriesFolders=false |
    .deleteEmptyFolders=false | .fileDate="none" | .rescanAfterRefresh="always" |
    .setPermissionsLinux=false | .chmodFolder="755" | .chownGroup="" |
    .episodeTitleRequired="always" | .skipFreeSpaceCheckWhenImporting=false |
    .minimumFreeSpaceWhenImporting=100 | .copyUsingHardlinks=true |
    .useScriptImport=false | .scriptImportPath="" | .importExtraFiles=false |
    .extraFileExtensions="srt" | .enableMediaInfo=true
  ' <<<"$config")"
  api PUT "$SONARR_URL/api/v3/config/mediamanagement" "$SONARR_API_KEY" "$config" >/dev/null
  echo "Sonarr naming and media-management baseline configured."
}

import_indexers() {
  local config_path="${1:-indexers.json}"
  local dry_run="${2:-0}"
  [[ -f "$config_path" ]] || {
    echo "Skipping Prowlarr indexer import: $config_path does not exist."
    return
  }

  local schemas existing count index item enabled schema_name payload name id field field_name field_value env_name
  jq -e '.indexers | type == "array"' "$config_path" >/dev/null ||
    fail "No indexers array found in $config_path."
  schemas="$(api GET "$PROWLARR_URL/api/v1/indexer/schema" "$PROWLARR_API_KEY")"
  existing="$(api GET "$PROWLARR_URL/api/v1/indexer" "$PROWLARR_API_KEY")"
  count="$(jq '.indexers | length' "$config_path")"
  for ((index = 0; index < count; index++)); do
    item="$(jq -c ".indexers[$index]" "$config_path")"
    enabled="$(jq -r '.enable // true' <<<"$item")"
    [[ "$enabled" == true ]] || continue
    schema_name="$(jq -r '.schemaName // empty' <<<"$item")"
    [[ -n "$schema_name" ]] || fail "Every indexer entry must include schemaName."
    payload="$(jq -c --arg name "$schema_name" '
      .[] |
      select(
        ((.name // "") | ascii_downcase) == ($name | ascii_downcase) or
        ((.definitionName // "") | ascii_downcase) == ($name | ascii_downcase)
      )
    ' <<<"$schemas" | head -n 1)"
    [[ -n "$payload" ]] || fail "No Prowlarr indexer schema found for '$schema_name'."
    name="$(jq -r --arg fallback "$(jq -r '.name' <<<"$payload")" '.name // $fallback' <<<"$item")"
    payload="$(jq --arg name "$name" --argjson enabled "$enabled" '.name=$name | .enable=$enabled' <<<"$payload")"

    while IFS= read -r field_name; do
      field_value="$(jq -c --arg name "$field_name" '.fields[$name]' <<<"$item")"
      if [[ "$(jq -r 'type' <<<"$field_value")" == string && "$(jq -r '.' <<<"$field_value")" == env:* ]]; then
        env_name="${field_value#*env:}"
        env_name="${env_name%\"}"
        [[ -n "${!env_name:-}" ]] || {
          echo "Skipping indexer '$name': missing environment variable $env_name."
          payload=''
          break
        }
        field_value="$(jq -Rn --arg value "${!env_name}" '$value')"
      fi
      if ! jq -e --arg name "$field_name" 'any(.fields[]; .name==$name)' <<<"$payload" >/dev/null; then
        fail "Indexer '$name' does not have a field named '$field_name'."
      fi
      payload="$(jq --arg name "$field_name" --argjson value "$field_value" \
        '.fields |= map(if .name==$name then .value=$value else . end)' <<<"$payload")"
    done < <(jq -r '.fields // {} | keys[]' <<<"$item")
    [[ -n "$payload" ]] || continue

    for field in priority appProfileId downloadClientId tags; do
      if jq -e --arg field "$field" 'has($field)' <<<"$item" >/dev/null; then
        payload="$(jq --arg field "$field" --argjson value "$(jq -c --arg field "$field" '.[$field]' <<<"$item")" '.[$field]=$value' <<<"$payload")"
      fi
    done
    if [[ "$dry_run" == 1 ]]; then
      jq . <<<"$payload"
      continue
    fi

    id="$(jq -r --arg name "$name" '.[] | select(.name==$name) | .id' <<<"$existing" | head -n 1)"
    if [[ -n "$id" ]]; then
      api PUT "$PROWLARR_URL/api/v1/indexer/$id" "$PROWLARR_API_KEY" "$(jq --argjson id "$id" '.id=$id' <<<"$payload")" >/dev/null
    else
      api POST "$PROWLARR_URL/api/v1/indexer" "$PROWLARR_API_KEY" "$payload" >/dev/null
    fi
    echo "Prowlarr indexer configured: $name"
  done
}

set_schema_field() {
  local payload="$1" name="$2" value="$3"
  jq --arg name "$name" --argjson value "$value" '
    if any(.fields[]; .name==$name) then
      .fields |= map(if .name==$name then .value=$value else . end)
    else error("schema field not found: \($name)") end
  ' <<<"$payload"
}

set_schema_field_if_present() {
  local payload="$1" name="$2" value="$3"
  jq --arg name "$name" --argjson value "$value" '
    .fields |= map(if .name==$name then .value=$value else . end)
  ' <<<"$payload"
}

upsert_download_client() {
  local app="$1" url="$2" key="$3" implementation="$4" name="$5" category_field="$6" category="$7" priority="$8"
  local schema payload existing id media_type priority_value
  schema="$(api GET "$url/api/v3/downloadclient/schema" "$key" | jq -ce --arg impl "$implementation" 'map(select(.implementation==$impl)) | first // error("schema not found")')" ||
    fail "Could not find $implementation download-client schema for $app."
  payload="$(jq --arg name "$name" --argjson priority "$priority" '
    .name=$name | .enable=true | .priority=$priority |
    .removeCompletedDownloads=($name=="SABnzbd") | .removeFailedDownloads=true | .tags=[]
  ' <<<"$schema")"
  if [[ "$name" == SABnzbd ]]; then
    payload="$(set_schema_field "$payload" host '"sabnzbd"')"
    payload="$(set_schema_field "$payload" port '8080')"
    payload="$(set_schema_field "$payload" apiKey "$(jq -Rn --arg value "$SABNZBD_API_KEY" '$value')")"
    payload="$(set_schema_field "$payload" username "$(jq -Rn --arg value "$SABNZBD_USER" '$value')")"
    payload="$(set_schema_field "$payload" password "$(jq -Rn --arg value "$SABNZBD_PASS" '$value')")"
    payload="$(set_schema_field "$payload" urlBase '""')"
    priority_value=-100
  else
    payload="$(set_schema_field "$payload" host '"gluetun"')"
    payload="$(set_schema_field "$payload" port '8080')"
    payload="$(set_schema_field "$payload" username "$(jq -Rn --arg value "${QBIT_USER:-admin}" '$value')")"
    payload="$(set_schema_field "$payload" password "$(jq -Rn --arg value "$QBIT_PASS" '$value')")"
    payload="$(set_schema_field_if_present "$payload" urlBase '""')"
    payload="$(set_schema_field_if_present "$payload" "${category_field%Category}ImportedCategory" "$(jq -Rn --arg value "${category}-imported" '$value')")"
    payload="$(set_schema_field_if_present "$payload" initialState '0')"
    payload="$(set_schema_field_if_present "$payload" sequentialOrder 'false')"
    payload="$(set_schema_field_if_present "$payload" firstAndLast 'false')"
    payload="$(set_schema_field_if_present "$payload" contentLayout '0')"
    priority_value=0
  fi
  media_type="${category_field%Category}"
  media_type="${media_type^}"
  payload="$(set_schema_field_if_present "$payload" "recent${media_type}Priority" "$priority_value")"
  payload="$(set_schema_field_if_present "$payload" "older${media_type}Priority" "$priority_value")"
  payload="$(set_schema_field "$payload" useSsl 'false')"
  payload="$(set_schema_field "$payload" "$category_field" "$(jq -Rn --arg value "$category" '$value')")"
  existing="$(api GET "$url/api/v3/downloadclient" "$key")"
  id="$(jq -r --arg name "$name" '.[] | select(.name==$name) | .id' <<<"$existing" | head -n 1)"
  if [[ -n "$id" ]]; then
    api PUT "$url/api/v3/downloadclient/$id" "$key" "$(jq --argjson id "$id" '.id=$id' <<<"$payload")" >/dev/null
  else
    api POST "$url/api/v3/downloadclient" "$key" "$payload" >/dev/null
  fi
  echo "$app download client configured: $name"
}

ensure_root_folder() {
  local app="$1" url="$2" key="$3" path="$4"
  if ! api GET "$url/api/v3/rootfolder" "$key" | jq -e --arg path "$path" '.[] | select(.path==$path)' >/dev/null; then
    api POST "$url/api/v3/rootfolder" "$key" "$(jq -nc --arg path "$path" '{path:$path}')" >/dev/null
  fi
  echo "$app root folder verified: $path"
}

configure_seerr_services() {
  bash ./scripts/bootstrap-seerr.sh "$SONARR_URL" "$RADARR_URL"
  docker compose restart seerr >/dev/null
}

main() {
  require_command curl
  require_command jq
  require_command python3
  require_command docker
  require_environment
  check_seerr_config_write_access

  export SONARR_API_KEY RADARR_API_KEY PROWLARR_API_KEY SABNZBD_API_KEY
  SONARR_API_KEY="$(get_api_key config/sonarr/config.xml)"
  RADARR_API_KEY="$(get_api_key config/radarr/config.xml)"
  PROWLARR_API_KEY="$(get_api_key config/prowlarr/config.xml)"
  SABNZBD_API_KEY="$(sed -n 's/^api_key[[:space:]]*=[[:space:]]*//p' config/sabnzbd/sabnzbd.ini | head -n 1)"
  [[ -n "$SABNZBD_API_KEY" ]] || fail "SABnzbd API key is missing."

  configure_qbittorrent
  configure_sabnzbd
  configure_arr_auth Sonarr "$SONARR_URL" "$SONARR_API_KEY" "$SONARR_USER" "$SONARR_PASS"
  configure_arr_auth Radarr "$RADARR_URL" "$RADARR_API_KEY" "$RADARR_USER" "$RADARR_PASS"
  configure_arr_auth Prowlarr "$PROWLARR_URL" "$PROWLARR_API_KEY" "$PROWLARR_USER" "$PROWLARR_PASS" v1
  configure_bazarr_auth
  configure_jellyfin
  initialize_seerr

  upsert_prowlarr_app Sonarr Sonarr SonarrSettings 'http://sonarr:8989' "$SONARR_API_KEY"
  upsert_prowlarr_app Radarr Radarr RadarrSettings 'http://radarr:7878' "$RADARR_API_KEY"
  import_indexers indexers.json 0
  configure_sonarr_baseline
  upsert_download_client Sonarr "$SONARR_URL" "$SONARR_API_KEY" Sabnzbd SABnzbd tvCategory tv 1
  upsert_download_client Radarr "$RADARR_URL" "$RADARR_API_KEY" Sabnzbd SABnzbd movieCategory movies 1
  upsert_download_client Sonarr "$SONARR_URL" "$SONARR_API_KEY" QBittorrent qBittorrent tvCategory tv 2
  upsert_download_client Radarr "$RADARR_URL" "$RADARR_API_KEY" QBittorrent qBittorrent movieCategory movies 2
  ensure_root_folder Sonarr "$SONARR_URL" "$SONARR_API_KEY" /data/media/tv
  ensure_root_folder Radarr "$RADARR_URL" "$RADARR_API_KEY" /data/media/movies
  configure_seerr_services
  echo "Bootstrap complete."
}

main_import_indexers() {
  require_command curl
  require_command jq
  local config_path="${1:-indexers.json}"
  local dry_run=0
  [[ "${2:-}" != '--dry-run' ]] || dry_run=1
  PROWLARR_API_KEY="$(get_api_key config/prowlarr/config.xml)"
  export PROWLARR_API_KEY
  import_indexers "$config_path" "$dry_run"
}

case "${1:-bootstrap}" in
  bootstrap)
    shift || true
    main "$@"
    ;;
  import-indexers)
    shift
    main_import_indexers "$@"
    ;;
  *)
    fail "Unknown bootstrap command: $1"
    ;;
esac
