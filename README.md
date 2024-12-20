## s3Uploader for Computer and Media Content Backups

Will upload files according to parameters in 10GB chunks during the night (starting at midnight) to an AWS S3 bucket. Can also be used with a backup of Plex media content for a given date.

* Intended to be used with [AWS CLI version 2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) and related [configuration](./aws)

* Example Usage:
    * Get help message: `./s3Main.sh -h`
    * Main backup type: `./s3Main.sh -m Main -b ../Backup -t . -B {S3-BUCKET} -T 7 -c DEEP_ARCHIVE`
    * Media Content backup type: `./s3Main.sh -m Media -b ../MediaBackup -t . -B {S3-BUCKET} -d {DATE} -T 7 -c DEEP_ARCHIVE`

* Will not limit upload bandwidth. To pause script in the middle of an upload use `kill -TSTP {PID}`. Unpause with `kill -CONT {PID}`

* To restore from backup:
    * Manually download from S3 online UI
    * Combine parts: `cat {source.pgp.part*} > source.pgp`
    * Decrypt: `gpg --output {source} --decrypt {source.pgp}`
    * Extract (if needed): `cd {destination} && tar -I xz -xvf {source}`
    * Mount dd partition (if needed): `sudo mount -o loop {image} {mount point}`
