import Foundation
import GRDB

enum Schema {
    static let version = 18

    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
            CREATE TABLE col (
                id INTEGER PRIMARY KEY,
                crt INTEGER NOT NULL,
                mod INTEGER NOT NULL,
                scm INTEGER NOT NULL,
                ver INTEGER NOT NULL,
                usn INTEGER NOT NULL,
                ls INTEGER NOT NULL
            );
            CREATE TABLE notes (
                id INTEGER PRIMARY KEY,
                guid TEXT NOT NULL,
                mid INTEGER NOT NULL,
                mod INTEGER NOT NULL,
                usn INTEGER NOT NULL,
                tags TEXT NOT NULL,
                flds TEXT NOT NULL,
                sfld TEXT NOT NULL,
                csum INTEGER NOT NULL,
                flags INTEGER NOT NULL,
                data TEXT NOT NULL
            );
            CREATE TABLE cards (
                id INTEGER PRIMARY KEY,
                nid INTEGER NOT NULL,
                did INTEGER NOT NULL,
                ord INTEGER NOT NULL,
                mod INTEGER NOT NULL,
                usn INTEGER NOT NULL,
                type INTEGER NOT NULL,
                queue INTEGER NOT NULL,
                due INTEGER NOT NULL,
                ivl INTEGER NOT NULL,
                factor INTEGER NOT NULL,
                reps INTEGER NOT NULL,
                lapses INTEGER NOT NULL,
                left INTEGER NOT NULL,
                odue INTEGER NOT NULL,
                odid INTEGER NOT NULL,
                flags INTEGER NOT NULL,
                data TEXT NOT NULL
            );
            CREATE TABLE revlog (
                id INTEGER PRIMARY KEY,
                cid INTEGER NOT NULL,
                usn INTEGER NOT NULL,
                ease INTEGER NOT NULL,
                ivl INTEGER NOT NULL,
                lastIvl INTEGER NOT NULL,
                factor INTEGER NOT NULL,
                time INTEGER NOT NULL,
                type INTEGER NOT NULL
            );
            CREATE TABLE decks (
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL,
                mtime_secs INTEGER NOT NULL,
                usn INTEGER NOT NULL,
                common TEXT NOT NULL,
                kind TEXT NOT NULL
            );
            CREATE TABLE deck_config (
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL,
                mtime_secs INTEGER NOT NULL,
                usn INTEGER NOT NULL,
                config TEXT NOT NULL
            );
            CREATE TABLE notetypes (
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL,
                mtime_secs INTEGER NOT NULL,
                usn INTEGER NOT NULL,
                config TEXT NOT NULL
            );
            CREATE TABLE tags (
                tag TEXT NOT NULL PRIMARY KEY COLLATE NOCASE,
                usn INTEGER NOT NULL,
                collapsed BOOLEAN NOT NULL
            ) WITHOUT ROWID;
            CREATE TABLE graves (
                oid INTEGER NOT NULL,
                type INTEGER NOT NULL,
                usn INTEGER NOT NULL,
                PRIMARY KEY (oid, type)
            ) WITHOUT ROWID;
            CREATE TABLE config (
                key TEXT NOT NULL PRIMARY KEY,
                usn INTEGER NOT NULL,
                mtime_secs INTEGER NOT NULL,
                val TEXT NOT NULL
            ) WITHOUT ROWID;
            CREATE TABLE media_meta (
                fname TEXT NOT NULL PRIMARY KEY,
                csum TEXT NOT NULL,
                mtime INTEGER NOT NULL,
                dirty INTEGER NOT NULL
            ) WITHOUT ROWID;

            CREATE INDEX ix_notes_usn ON notes (usn);
            CREATE INDEX ix_notes_csum ON notes (csum);
            CREATE INDEX ix_notes_mid ON notes (mid);
            CREATE INDEX ix_notes_guid ON notes (guid);
            CREATE INDEX ix_cards_usn ON cards (usn);
            CREATE INDEX ix_cards_nid ON cards (nid);
            CREATE INDEX ix_cards_sched ON cards (did, queue, due);
            CREATE INDEX ix_cards_odid ON cards (odid) WHERE odid != 0;
            CREATE INDEX ix_revlog_usn ON revlog (usn);
            CREATE INDEX ix_revlog_cid ON revlog (cid);
            CREATE UNIQUE INDEX ix_decks_name ON decks (name COLLATE NOCASE);
            CREATE UNIQUE INDEX ix_notetypes_name ON notetypes (name COLLATE NOCASE);
            """)
        }

        return migrator
    }
}
