#ifndef SQLITE_VEC1_H
#define SQLITE_VEC1_H

#include <sqlite3.h>

int sqlite3_vec1_extra_init(const char *z);
int sqlite3_extension_init(sqlite3 *db, char **pzErrMsg, const sqlite3_api_routines *pApi);

#endif
