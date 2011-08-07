// Copyright (C) 1989-1998 by Symantec
// Copyright (C) 2000-2011 by Digital Mars
// All Rights Reserved
// http://www.digitalmars.com
// Written by Walter Bright
/*
 * This source file is made available for personal use
 * only. The license is in /dmd/src/dmd/backendlicense.txt
 * or /dm/src/dmd/backendlicense.txt
 * For any other uses, please contact Digital Mars.
 */

//#pragma once
#ifndef TASSERT_H
#define TASSERT_H 1

/*****************************
 * Define a local assert function.
 */

#undef assert
#define assert(e)       ((e) || (local_assert(__LINE__), 0))

#if __clang__

void util_assert ( char * , int ) __attribute__((analyzer_noreturn));

static void local_assert(int line)
{
    util_assert(__file__,line);
    __buildtin_unreachable();
}

#else

#ifdef _MSC_VER
__declspec(noreturn)
#endif
void util_assert ( char * , int );
#ifndef _MSC_VER
#pragma noreturn(util_assert)
#endif

#ifdef _MSC_VER
__declspec(noreturn)
#endif
static void local_assert(int line)
{
    util_assert(__file__,line);
}

#ifndef _MSC_VER
#pragma noreturn(local_assert)
#endif

#endif


#endif /* TASSERT_H */
