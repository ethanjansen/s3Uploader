#!/bin/bash

#Global Vars
AWSLOCATION=/root/.local/bin

ENCRYPTIONRECIPIENT={REDACTED}

MODE=
BACKUP=
AMAZONDIR=
BUCKET=
NAME=
DATE=
TIME=
CLASS=

CHUNKSIZE=24

FREE=
ExistingArray=

MAINARGS=0
FIXARGS=0
CHECKARGS=0
MEDIAARGS=0

#Functions
printUsage() {
	echo "Run as root and use complete paths."
	echo "s3.sh -m [Main|Fix|Check|Media] {-b [Backup Directory] -t [Temp Directory] -B [S3 Bucket] {-n Name} {-d Date}} {-h Help}"
	echo ""
	echo "Mode: Main"
	echo "  Iterates through the backup directory encrypting, splitting (if necessary), and uploading to S3 Bucket."
	echo "  Requires: -b -t -B -T -c"
	echo "Mode: Fix"
	echo "  Assumes backup directory is already encrypted and split and uploads them to appropriate folder in S3 Bucket."
	echo "  Requires: -b -t -B -n -d -T -c"
 	echo "Mode: Check"
	echo "  Calculates the multipart checksum for the file designated by --name in and compares with the appropriate uploaded ARN."
	echo "  Requires: -t -B -n -d"
	echo "Mode: Media"
	echo "  For use when uploading media backup. Checks against log to see what needs to be uploaded. Compresses what is necessary, encrypts, and splits (if needed) and uploads to a folder with the current date. Always uploads Metadata and log of upload."
	echo "  Requires: -b -t -B -d -T -c"
	echo ""
	echo "Arguments:"
	echo "  -m --mode	Required. Determines which mode to run in. See Modes list above."
	echo "  -b --backup	Required unless using Check mode. When using the Main or Fix modes this is the directory containing the date separated, and compressed backups to upload. When using the Media mode this is the directory containing MediaContent and Metadata."
	echo "  -t --temp	Required. This is the 'temp' working directory where default logs, temporary encryptions, and temporary splits are stored."
	echo "  -B --bucket	Required. AWS S3 Bucket that holds the uploads."
	echo "  -n --name	For use with Fix and Check modes. When using Fix mode, this is the original local backup name in the appropriate date to uploaded to AWS - using existing files in temp split directory. When using Check mode, this is the file to be checked against the uploaded ARN."
	echo "  -d --date	For use with Fix, Check, and Media modes. When using Fix or Check modes, this is the date of the original backup and will be used to upload/check to/with the appropriate folder. When using Media mode, this is the current date."
	echo "  -T --time	Required unless using Check mode. Determines the hour to begin pausing uploads, where uploading starts at midnight."
	echo "  -c --class	Required unless using Check mode. Determines the AWS storage class."
	echo "  -h --help	Displays this dialogue."
}

compareArgs() {
	if [[ $1 -ne $2 ]]; then
		echo "Incorrect use of arguments for selected Mode."
		echo ""
		printUsage
		exit 1
	fi
}

setup() {
	mkdir -p "$AMAZONDIR"
	cd "$AMAZONDIR"
	mkdir -p encryption
	mkdir -p parts
	mkdir -p temp
	touch existing.json
	touch log.txt
	touch mediaUploaded.txt
	touch newMediaUploaded.txt
}

checkHash() {
	set -euo pipefail
	file=$1
	
	partSizeInMb=$2
	fileSizeInMb=$(du -m "$file" | cut -f 1)
	parts=$((fileSizeInMb / partSizeInMb))
	if [[ "$parts" -eq 0 ]]; then etag=$(md5sum "$file" | awk '{print $1}'); echo "${etag}"; return 0; fi
	
	if [[ $((fileSizeInMb % partSizeInMb)) -gt 0 ]]; then
		parts=$((parts + 1))
	fi

	checksumFile=$(mktemp -t s3md5.XXXXXXXXXXXXX)
	for (( part=0; part<parts; part++ )); do
		skip=$((partSizeInMb * part))
		dd bs=1M count="$partSizeInMb" skip=$skip if="$file" 2> /dev/null | md5sum >> "$checksumFile"
	done

	etag=$(echo $(xxd -r -p "$checksumFile" | md5sum)-$parts | sed 's/ --/-/')
	echo "${etag}"
	rm "$checksumFile"
}

findExisting() {
	#Added ? after .[] in both jq to fix: "cannot iterate over null"
	$AWSLOCATION/aws s3api list-objects --bucket "$BUCKET" --query 'Contents[].{ETag: ETag, Key: Key, Size: Size}' --output json > "$AMAZONDIR"/existing.json 2>&1
	mapfile -t ExistingArray < <( jq -r '.[]?.Key' "$AMAZONDIR"/existing.json )

	if [[ $# -eq 3 ]]; then
		ETag=$(< "$AMAZONDIR"/existing.json jq -r '.[]? | select(.Key | contains('\""${1}"/"${2}"/"${3}"\"')) | .ETag' | tr -d '"')
		ComputedETag=$(checkHash "$3" $CHUNKSIZE)
		echo "$1/$2/$3 md5 Check: " | ts | tee -a "$AMAZONDIR"/log.txt
		echo "   S3:    $ETag" | tee -a "$AMAZONDIR"/log.txt
		echo "   Local: $ComputedETag" | tee -a "$AMAZONDIR"/log.txt
		if [[ $ETag == "$ComputedETag" ]]; then echo "   Good" | tee -a "$AMAZONDIR"/log.txt; return 0; else echo "   Missing or Bad" | tee -a "$AMAZONDIR"/log.txt; return 1; fi
	fi
}

findAllPartsExisting() {
	findExisting

	count=0
	for ((i=0; i<${#ExistingArray[@]}; i++)); do
		[[ "${ExistingArray[$i]}" == *"$1/$2"* ]] && ((count++))
	done

	[[ $((($3 / 10737418240) + 1)) -eq count ]] && return 0 || return 1
}

checkIfFreeSpace() {
	[[ $FREE -gt $(($1 * $2 + 10737418240)) ]] && return 0 || return 1
}

checkIfGreaterThanTen() {
	[[ $1 -gt 10737418240 ]] && return 0 || return 1
}

checkTime() {
	hour=$(date +%H)
	(( hour=(10#$hour) ))
	while (( hour > TIME )); do
		echo "waiting"
		sleep 600
		hour=$(date +%H)
		(( hour=(10#$hour) ))
	done
}

checkInternet() {
	connected=0
	until (ping -q -c 1 -W 1 8.8.8.8 >/dev/null); do
		connected=1
		echo "no internet"
		sleep 600
	done
	return $connected
}

encryption() {
	echo "encryption" | ts | tee -a "$AMAZONDIR"/log.txt
	gpg --output "$AMAZONDIR/encryption/${1}.pgp" --encrypt --recipient $ENCRYPTIONRECIPIENT "$1" 2>&1 | ts | tee -a "$AMAZONDIR"/log.txt
}

splitting() {
	echo "split" | ts | tee -a "$AMAZONDIR"/log.txt
	split -b 10G -d "$AMAZONDIR/encryption/${1}.pgp" "$AMAZONDIR/parts/${1}.pgp.part" 2>&1 | ts | tee -a "$AMAZONDIR"/log.txt
}

cleanup() {
	rm -f "${AMAZONDIR}"/encryption/*
	rm -f "${AMAZONDIR}"/parts/*
}

upload() {
	echo "starting upload" | ts | tee -a "$AMAZONDIR"/log.txt
	for file in *; do
		checkTime
		checkInternet
		$AWSLOCATION/aws s3 cp "$file" "s3://${BUCKET}/${1}/${2}/" --sse --expected-size 10750000000 --storage-class "$CLASS" --no-progress 2>&1 | ts | tee -a "$AMAZONDIR"/log.txt
		checkInternet || continue
		findExisting "$1" "$2" "$file" || exit 1
	done

	if findAllPartsExisting "$1" "$2" "$3"; then echo "UPLOAD COMPLETED SUCCESSFULLY" | ts | tee -a "$AMAZONDIR"/log.txt; cleanup; else echo "UPLOAD FAILED" | ts | tee -a "$AMAZONDIR"/log.txt; exit 1; fi
}

copy() {
	size=$(rsync -an --stats --exclude "Plex Media Server.tar.xz" --exclude-from "$AMAZONDIR/mediaUploaded.txt" "${BACKUP}/" "$AMAZONDIR/temp/" | grep "Total file size:" | awk '{print $4}')
	checkIfFreeSpace "$size" 3 || { echo "ERROR: Not enough free space for media copy!" | ts | tee -a "$AMAZONDIR"/log.txt; exit 1; }
	rsync -anv --exclude "Plex Media Server.tar.xz" --exclude-from "$AMAZONDIR/mediaUploaded.txt" "${BACKUP}/" "$AMAZONDIR/temp/" | head -n -3 | tail -n +2 | sed -e '/\/$/d' -e 's/\[\([^]]*\)\]/\\[\1\]/g' | tee "$AMAZONDIR/newMediaUploaded.txt"
	rsync -amv --exclude "Plex Media Server.tar.xz" --exclude-from "$AMAZONDIR/mediaUploaded.txt" "${BACKUP}/" "$AMAZONDIR/temp/"
	rsync -a "$AMAZONDIR/newMediaUploaded.txt" "$AMAZONDIR/temp/"
	[ ! -s "$AMAZONDIR/temp/newMediaUploaded.txt" ] && rm "$AMAZONDIR/temp/newMediaUploaded.txt"
}

compress() {
	dirs=( "$1"/*/ )
	cd "$1"
	for ((i=0; i<${#dirs[@]}; i++)); do
		[ "${dirs[$i]}" = "$1/*/" ] && continue
		name=$(echo "${dirs[$i]}" | sed 's:/*$::' | awk -F/ '{print $NF}')
		size=$(du -bs "$name" | awk '{print $1}')
		checkIfFreeSpace "$size" 1 || { echo "ERROR: Not enough free space to compress ${name}!" | ts | tee -a "$AMAZONDIR"/log.txt; exit 1; }
		echo "Compressing: $name" | ts | tee -a "$AMAZONDIR"/log.txt
		tar -I "xz -e -T 0" -cpf "${name}.tar.xz" "${name}"
		mv "${name}.tar.xz" "$AMAZONDIR/temp/"
	done
}

compressPrompt() {
	while true; do
		read -r -p "${AMAZONDIR}/temp already contains files. Do you wish to continue with existing temp files or abort? (C/A): " answer
		case $answer in
			[Cc]* ) echo "continuing"; break;;
			[Aa]* ) echo "${AMAZONDIR}/temp already contains files. Aborting due to conflicts!" | ts | tee -a "$AMAZONDIR"/log.txt; exit 1;;
			* ) echo "Please answer C or A.";;
		esac
	done
}

main() {
	setup
	FREE=$(df -P "$AMAZONDIR" -B 1 | tail -1 | awk '{print $4}')
	cd "$BACKUP"

	for majorDirectory in *; do
		echo "$majorDirectory" | ts | tee -a "$AMAZONDIR"/log.txt
		cd "$majorDirectory"
		for backup in *; do
			name=$(echo "$backup" | cut -d '.' -f1)
			size=$(du -b "$backup" | awk '{print $1}')

			findAllPartsExisting "$majorDirectory" "$name" "$size" && continue
			

			if [[ -n $(ls "${AMAZONDIR}"/parts/"${name}"* 2> /dev/null) ]]; then cd "$AMAZONDIR/parts/"; else
				checkIfFreeSpace "$size" 2 || { echo "ERROR: Not enough free space for $name backup!" | ts | tee -a "$AMAZONDIR"/log.txt; exit 1; }
			
				echo "$majorDirectory	$backup" | ts | tee -a "$AMAZONDIR"/log.txt
				encryption "$backup"

			
				if checkIfGreaterThanTen "$size"; then splitting "$backup"; cd "$AMAZONDIR/parts/"; else cd "$AMAZONDIR/encryption/"; fi
			fi

			upload "$majorDirectory" "$name" "$size"

			cd "${BACKUP}/${majorDirectory}"
		done
		cd "$BACKUP"
	done
	echo "completed everything" | ts | tee -a "$AMAZONDIR"/log.txt
	exit
}

fix() {
	setup
	name=$(echo "$NAME" | rev | cut -d '/' -f1 | rev | cut -d '.' -f1)

	size=$(du -b "$NAME" | awk '{print $1}')

	cd "$AMAZONDIR/parts"
	upload "$DATE" "$name" "$size"

	echo "completed everything" | ts | tee -a "$AMAZONDIR"/log.txt
	exit
}

check() {
	setup
	cd "$(dirname "$NAME")"
	filename=$(echo "$NAME" | rev | cut -d '/' -f1 | rev)
	name=$(echo "$filename" | cut -d '.' -f1)

	findExisting "$DATE" "$name" "$filename" || exit 1
	exit
}

media() {
	setup
	FREE=$(df -P "$AMAZONDIR" -B 1 | tail -1 | awk '{print $4}')
	cd "$BACKUP"

	findExisting
	
	if [[ -n $(ls "${AMAZONDIR}/temp/" 2> /dev/null) ]]; then compressPrompt; else
				
		if ! grep -q 'Key' "$AMAZONDIR/existing.json"; then 
			rsync -anv --exclude "Plex Media Server.tar.xz" "${BACKUP}/" "$AMAZONDIR/temp/" | head -n -3 | tail -n +2 | sed -e '/\/$/d' -e 's/\[\([^]]*\)\]/\\[\1\]/g' | tee "$AMAZONDIR"/newMediaUploaded.txt
			rsync -a "$AMAZONDIR/newMediaUploaded.txt" "$AMAZONDIR/temp/"
			compress "$BACKUP"
		else 
			copy
			compress "$AMAZONDIR/temp"
			rm -rf "${AMAZONDIR}"/temp/*/
		fi
		
		rsync -anv --exclude "Plex Media Server.tar.xz" "${BACKUP}/" "$AMAZONDIR/temp/" | head -n -3 | tail -n +2 | sed -e '/\/$/d' -e 's/\[\([^]]*\)\]/\\[\1\]/g' | tee "$AMAZONDIR"/mediaUploaded.txt
		rsync -a "${BACKUP}/Plex Media Server.tar.xz" "${AMAZONDIR}/temp/"
	fi
	
	cd "${AMAZONDIR}/temp"
	for backup in *; do
		name=$(echo "$backup" | cut -d '.' -f1)
		size=$(du -b "$backup" | awk '{print $1}')

		findAllPartsExisting "$DATE" "$name" "$size" && continue
		
		if [[ -n $(ls "${AMAZONDIR}/parts/${name}"* 2> /dev/null) ]]; then cd "$AMAZONDIR/parts/"; else
			checkIfFreeSpace "$size" 2 || { echo "ERROR: Not enough free space for $name backup!" | ts | tee -a "$AMAZONDIR"/log.txt; exit 1; }
	
			echo "MediaContent: $backup" | ts | tee -a "$AMAZONDIR"/log.txt
			encryption "$backup"
	
			if checkIfGreaterThanTen "$size"; then splitting "$backup"; cd "$AMAZONDIR/parts/"; else cd "$AMAZONDIR/encryption/"; fi
		fi

		upload "$DATE" "$name" "$size"

		cd "${AMAZONDIR}/temp"
	done
	rm -f "${AMAZONDIR}"/temp/*
	echo "completed everything" | ts | tee -a "$AMAZONDIR"/log.txt
	exit
}


#Main
#Check for arguments
if [[ ! $# -gt 0 ]]; then
	printUsage
	exit 1
fi

while [[ -n $1 ]]; do
	case $1 in
		-m | --mode )		shift
					MODE=$1
					;;
		-b | --backup )		shift
					BACKUP=$(readlink -f "$1")
					[[ -n $BACKUP ]] && { ((MAINARGS++)); ((FIXARGS++)); ((MEDIAARGS++)); }
					;;
		-t | --temp )		shift
					AMAZONDIR=$(readlink -f "$1")
					[[ -n $AMAZONDIR ]] && { ((MAINARGS++)); ((FIXARGS++)); ((CHECKARGS++)); ((MEDIAARGS++)); }
					;;
		-B | --bucket )		shift
					BUCKET=$1
					[[ -n $BUCKET ]] && { ((MAINARGS++)); ((FIXARGS++)); ((CHECKARGS++)); ((MEDIAARGS++)); }
					;;
		-n | --name )		shift
					NAME=$(readlink -f "$1")
					[[ -n $NAME ]] && { ((FIXARGS++)); ((CHECKARGS++)); }
					;;
		-d | --date )		shift
					DATE=$1
					[[ -n $DATE ]] && { ((FIXARGS++)); ((CHECKARGS++)); ((MEDIAARGS++)); }
					;;
		-T | --time )		shift
					TIME=$1
					[[ -n $TIME ]] && { ((MAINARGS++)); ((FIXARGS++)); ((MEDIAARGS++)); }
					;;
		-c | --clas )		shift
					CLASS=$1
					[[ -n $CLASS ]] && { ((MAINARGS++)); ((FIXARGS++)); ((MEDIAARGS++)); }
					;;
		-h | --help )		printUsage
					exit 1
					;;
	esac
	shift
done

case $MODE in
	Main )		compareArgs "$MAINARGS" 5
			main
			exit
			;; 
	Fix )		compareArgs "$FIXARGS" 7
			fix
			exit
			;;
	Check )		compareArgs "$CHECKARGS" 4
			check
			exit
			;;
	Media )		compareArgs "$MEDIAARGS" 6
			media
			exit
			;;
	* )		echo "Incorrect Mode."
			echo ""
			printUsage
			exit 1
			;;
esac
