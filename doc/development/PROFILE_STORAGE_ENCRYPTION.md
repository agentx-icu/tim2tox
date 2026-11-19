# Local chat storage encryption

Setting a Tox profile password protects Tim2Tox message history and offline queue files. The Flutter service uses the profile's storage key for new writes and migrates existing files in its account directory when opened. Hosts that enable a password on a live profile can await `waitForProfileStorageMigration()` after `rekeyLiveProfilePassphraseBytes()` succeeds. The synchronous result covers the native profile write. The migration future reports completion of the separate chat file updates.

## Key and file formats

The native session generates a random 256-bit storage key and commits it in a versioned trailer inside the Tox profile before using it. The trailer follows the end section understood by toxcore and is covered by the existing authenticated profile encryption. Authenticated file encryption uses XChaCha20-Poly1305 with a fresh nonce per snapshot or archive record. Its associated data distinguishes history snapshots, archive records and queue snapshots. Dart never receives the key.

Snapshots wrap the original UTF-8 JSON in a versioned envelope containing the ciphertext. The history version is reserved so readers with the schema downgrade guard refuse to replace the file. Archive records remain independently newline-delimited and authenticated. Appends do not rewrite the archive. Account-directory transfers keep the original logical digests, so upgrading a file's encryption does not itself count as editing rows during a partial merge.

Plaintext source files are replaced individually using a flushed encrypted staging file. A crash can leave a mixture of old plaintext and complete encrypted files. Migration can reopen both formats and retry. The account passphrase must remain available while encrypted files are in use. A caller missing the storage key or using a different key must preserve those files.

## Rekey and recovery

Changing the profile password re-wraps the same data key as part of the atomic profile replace. This avoids a multi-file password transition and keeps old data readable even if the application exits immediately after changing the password. The data key itself is stable. An earlier profile backup and the password that opens it can still decrypt ciphertext written under that key. Removing the password keeps the data key in the now-plaintext profile, so access to that profile is sufficient to decrypt chat storage.

Byte-preserving profile backups retain the key, including exports that decrypt or re-encrypt the full savedata with a different password. Keep a matching profile backup alongside backed-up history and queue files. A profile exported before the data key was created cannot unlock those files. Other Tox clients and older Tim2Tox native builds can ignore the trailer when reading a profile and strip it when saving the profile. Restoring history after such a save requires a matching profile backup with the trailer intact.

Tim2Tox migrates the history and queue artifacts it owns, including known backup and staging files inside its configured account paths. An old queue in the shared application support directory has no identity marker. A protected session without an explicit queue path uses a directory keyed by its Tox public key. A host with evidence of who owns an older shared queue can copy it into that account's configured path before opening the service. Host preferences, attachments, independently created backups, and other files are outside these two stores.
