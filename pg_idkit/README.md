# pg_idkit

A pure PL/pgSQL port of the popular [Rust version](https://github.com/VADOSWARE/pg_idkit).

## Installation

`dbdev install kiwicopple-pg_idkit --connection <CONNECTION>`

or

`select * from dbdev('kiwicopple-pg_idkit')`

then:

`create extension pg_idkit;`

or to install in a separate schema (recommended):

`create extension pg_idkit with schema extensions;`

## Usage

Function signatures follows a similar pattern to the built-in

- `gen_random_uuid_v6()` - generate a random UUID v6
- `gen_random_uuid_v7()` - generate a random UUID v7