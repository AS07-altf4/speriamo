#!/usr/bin/env bash

# Function to get the latest Purpur server details and download it
get_latest_server() {
  # Fetch the latest Minecraft version and build number from Purpur API
  MC_VERSION=$(curl -s "https://api.purpurmc.org/v2/purpur" | jq -r -e '.versions[-1]' 2>/dev/null)
  if [[ $? -ne 0 ]]; then
    echo "Failed to fetch Minecraft version."
    exit 1
  fi

  LATEST_BUILD=$(curl -s "https://api.purpurmc.org/v2/purpur/$MC_VERSION" | jq -r -e '.builds[-1]' 2>/dev/null)
  if [[ $? -ne 0 ]]; then
    echo "Failed to fetch latest build."
    exit 1
  fi

  SERVER_JAR_FILENAME=$(curl -s "https://api.purpurmc.org/v2/purpur/$MC_VERSION/$LATEST_BUILD" | jq -r -e '.downloads.application.name' 2>/dev/null)
  if [[ $? -ne 0 ]]; then
    echo "Failed to fetch server JAR filename."
    exit 1
  fi

  SERVER_JAR_SHA256=$(curl -s "https://api.purpurmc.org/v2/purpur/$MC_VERSION/$LATEST_BUILD" | jq -r -e '.downloads.application.sha256' 2>/dev/null)
  if [[ $? -ne 0 ]]; then
    echo "Failed to fetch server JAR SHA256."
    exit 1
  fi

  SERVER_JAR_URL="https://api.purpurmc.org/v2/purpur/$MC_VERSION/$LATEST_BUILD/download/$SERVER_JAR_FILENAME"

  # Download the server JAR file
  printf "%s\n" "Downloading Purpur $MC_VERSION build $LATEST_BUILD..."
  echo "$SERVER_JAR_SHA256 $SERVER_JAR_FILENAME" > purpursha256.txt
  if ! wget --quiet -O "$SERVER_JAR_FILENAME" -T 60 "$SERVER_JAR_URL"; then
    echo "Failed to download Purpur JAR file."
    exit 1
  fi

  # Verify the integrity of the downloaded JAR file
  if ! sha256sum -c purpursha256.txt --status; then
    echo "SHA256 checksum verification failed for the Purpur server JAR."
    exit 1
  fi
}

# JVM flag constants for optimization
AIKAR_FLAGS_CONSTANT="-XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 -XX:+UnlockExperimentalVMOptions -XX:+DisableExplicitGC -XX:+AlwaysPreTouch -XX:G1NewSizePercent=30 -XX:G1MaxNewSizePercent=40 -XX:G1HeapRegionSize=8M -XX:G1ReservePercent=20 -XX:G1HeapWastePercent=5 -XX:G1MixedGCCountTarget=4 -XX:InitiatingHeapOccupancyPercent=15 -XX:G1MixedGCLiveThresholdPercent=90 -XX:G1RSetUpdatingPauseTimePercent=5 -XX:SurvivorRatio=32 -XX:+PerfDisableSharedMem -XX:MaxTenuringThreshold=1 -Dusing.aikars.flags=https://mcflags.emc.gs -Daikars.new.flags=true"
ZGC_FLAGS_CONSTANT="-XX:+UseZGC -XX:+IgnoreUnrecognizedVMOptions -XX:+UnlockExperimentalVMOptions -XX:+UnlockDiagnosticVMOptions -XX:-OmitStackTraceInFastThrow -XX:+ShowCodeDetailsInExceptionMessages -XX:+DisableExplicitGC -XX:-UseParallelGC -XX:-UseParallelOldGC -XX:+PerfDisableSharedMem -XX:-ZUncommit -XX:ZUncommitDelay=300 -XX:ZCollectionInterval=5 -XX:ZAllocationSpikeTolerance=2.0 -XX:+AlwaysPreTouch -XX:+UseTransparentHugePages -XX:LargePageSizeInBytes=2M -XX:+UseLargePages -XX:+ParallelRefProcEnabled"

# Wait for working internet access
wget --quiet --spider https://purpurmc.org 2>&1
if [ $? -eq 1 ]; then
  echo "No internet access - exiting"
  sleep 10
  exit 1
fi

# Set default values for variables if not provided
if [[ -z "$DEVICE_HOSTNAME" ]]; then
  DEVICE_HOSTNAME=balenaminecraftserver
fi

if [[ -z "$JAR_FILE" ]]; then
  JAR_FILE="purpur.jar"
fi

# Get the total memory available on the Raspberry Pi
TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}')
RAM="${TOTAL_MEM}M"

# Select the appropriate JVM flags
if [[ -z "$FLAGS" ]]; then
  if [[ -n "$AIKAR_FLAGS" ]]; then
    FLAGS="$AIKAR_FLAGS_CONSTANT"
  elif [[ -n "$ZGC_FLAGS" ]]; then
    FLAGS="$ZGC_FLAGS_CONSTANT"
  fi
fi

# Set the device hostname
printf "%s\n" "Setting device hostname to: $DEVICE_HOSTNAME"
curl -s -X PATCH --header "Content-Type:application/json" \
  --data '{"network": {"hostname": "'"${DEVICE_HOSTNAME}"'"}}' \
  "$BALENA_SUPERVISOR_ADDRESS/v1/device/host-config?apikey=$BALENA_SUPERVISOR_API_KEY" >/dev/null

# Download a server JAR if we don't already have a valid one and copy the server files into the directory on first run
printf "\n\n%s\n\n" "Starting balenaMinecraftServer..."
if [[ -z "$ENABLE_UPDATE" ]]; then
  if [[ ! -e "/servercache/copied.txt" ]]; then
    printf "%s\n" "Copying config"
    cp -R /serverfiles /usr/src/
    touch /servercache/copied.txt
  else
    printf "%s\n" "Config already copied"
  fi

  cd /usr/src/serverfiles/ || exit

  printf "%s" "Checking server JAR... "
  if [[ ! -e "$JAR_FILE" ]]; then
    printf "%s\n" "No server JAR found."
    get_latest_server
  fi

  if [[ ! -e "purpursha256.txt" ]] || ! sha256sum -c purpursha256.txt --status; then
    printf "%s\n" "Server JAR not valid or checksum file missing."
    get_latest_server
  else
    printf "%s\n" "Found a valid server file. It's called: $(ls *.jar). Use ENABLE_UPDATE to update."
  fi
else
  printf "%s\n" "Forcing server update"
  get_latest_server
fi

if [[ -n "$ENABLE_CONFIG_UPDATE" ]]; then
  printf "%s\n" "Forcing config copy"
  cp -R /serverfiles /usr/src/
fi

# Make sure we are in the file volume
cd /usr/src/serverfiles/ || exit

if [[ -z "$CUSTOM_COMMAND" ]]; then
  printf "%s\n" "Starting JAR file with: $RAM of RAM"
  java -Xms$RAM -Xmx$RAM $FLAGS -jar $JAR_FILE nogui
else
  $CUSTOM_COMMAND
fi

# Don't overload the server if the start fails
sleep 10