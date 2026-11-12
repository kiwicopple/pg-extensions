# WAL per keystroke, decomposed

Postgres: 16.4 (Postgres.app)
Machine:  Apple M4, 10 CPU, 24 GB, macOS 27.0.1
Date:     2026-11-10 19:09 +08
Settings: autovacuum=off, autovacuum_naptime=1min, autovacuum_vacuum_cost_delay=2ms, autovacuum_vacuum_cost_limit=-1, autovacuum_vacuum_scale_factor=0.2, autovacuum_vacuum_threshold=50, checkpoint_timeout=30min, default_toast_compression=pglz, fsync=off, full_page_writes=on, max_wal_size=8GB, shared_buffers=512MB, synchronous_commit=on, wal_compression=off, wal_level=replica
Code:     git cdea487; NDOCS=100; QUICK=0

100 documents per shape, 2000 keystrokes per run (one pgbench client, random document and position, 80% insert / 20% delete of one character). Bytes per edit. 'LSN' is pg_wal_lsn_diff over the run (what research/benchmarks/text.md reports); 'records' and 'FPI' are pg_waldump --stats=record totals (FPI after wal_compression), 'heap' / 'btree' / 'other' split the waldump total by resource manager (Heap+Heap2, Btree, the rest: commits, XLOG, sequences).

## Bytes per edit

| size | shape | phase | wal_compression | LSN | records | FPI | FPI share | heap | btree | other |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 kB | plain text (lz4) | cold | off | 541 | 458 | 70 | 13% | 490 | 4 | 34 |
| 1 kB | plain text (lz4) | warm | off | 432 | 419 | 0 | 0% | 384 | 1 | 34 |
| 1 kB | plain text (lz4) | cold | pglz | 493 | 413 | 67 | 14% | 444 | 2 | 34 |
| 1 kB | plain text (lz4) | cold | lz4 | 480 | 405 | 63 | 13% | 431 | 3 | 34 |
| 1 kB | plain text (lz4) | reuse | off | 518 | 405 | 101 | 20% | 469 | 2 | 34 |
| 1 kB | plain text (lz4) | reuse | lz4 | 478 | 403 | 63 | 14% | 430 | 2 | 34 |
| 1 kB | plain text (lz4) | reuse | pglz | 501 | 419 | 69 | 14% | 452 | 2 | 34 |
| 1 kB | plain text (pglz) | cold | off | 552 | 464 | 74 | 14% | 500 | 4 | 34 |
| 1 kB | plain text (pglz) | warm | off | 427 | 415 | 0 | 0% | 380 | 1 | 34 |
| 1 kB | plain text (pglz) | cold | pglz | 490 | 410 | 68 | 14% | 441 | 2 | 34 |
| 1 kB | plain text (pglz) | cold | lz4 | 492 | 416 | 64 | 13% | 442 | 3 | 34 |
| 1 kB | plain text (pglz) | reuse | off | 518 | 401 | 104 | 21% | 469 | 2 | 34 |
| 1 kB | plain text (pglz) | reuse | lz4 | 470 | 394 | 64 | 14% | 423 | 1 | 34 |
| 1 kB | plain text (pglz) | reuse | pglz | 491 | 408 | 70 | 15% | 442 | 2 | 34 |
| 1 kB | yseq_ (lz4) | cold | off | 3376 | 3216 | 130 | 4% | 3177 | 135 | 34 |
| 1 kB | yseq_ (lz4) | warm | off | 3706 | 3677 | 0 | 0% | 3510 | 132 | 34 |
| 1 kB | yseq_ (lz4) | cold | pglz | 4506 | 4096 | 378 | 8% | 4303 | 137 | 34 |
| 1 kB | yseq_ (lz4) | cold | lz4 | 5091 | 4541 | 514 | 10% | 4861 | 161 | 34 |
| 1 kB | yseq_ (lz4) | reuse | off | 5300 | 5045 | 219 | 4% | 5037 | 193 | 34 |
| 1 kB | yseq_ (lz4) | reuse | lz4 | 5711 | 5445 | 227 | 4% | 5439 | 199 | 34 |
| 1 kB | yseq_ (lz4) | reuse | pglz | 6083 | 5785 | 258 | 4% | 5810 | 200 | 34 |
| 1 kB | yseq_ (pglz) | cold | off | 3016 | 2871 | 118 | 4% | 2824 | 131 | 34 |
| 1 kB | yseq_ (pglz) | warm | off | 3259 | 3229 | 0 | 0% | 3063 | 132 | 34 |
| 1 kB | yseq_ (pglz) | cold | pglz | 4049 | 3469 | 548 | 14% | 3850 | 134 | 34 |
| 1 kB | yseq_ (pglz) | cold | lz4 | 4188 | 3744 | 415 | 10% | 3990 | 135 | 34 |
| 1 kB | yseq_ (pglz) | reuse | off | 4248 | 4039 | 179 | 4% | 4049 | 134 | 34 |
| 1 kB | yseq_ (pglz) | reuse | lz4 | 4530 | 4310 | 186 | 4% | 4323 | 140 | 34 |
| 1 kB | yseq_ (pglz) | reuse | pglz | 4831 | 4596 | 200 | 4% | 4601 | 161 | 34 |
| 1 kB | ydoc_ | cold | off | 1952 | 1147 | 772 | 40% | 1194 | 689 | 36 |
| 1 kB | ydoc_ | warm | off | 993 | 958 | 7 | 1% | 645 | 284 | 36 |
| 1 kB | ydoc_ | cold | pglz | 1618 | 977 | 611 | 38% | 1007 | 545 | 36 |
| 1 kB | ydoc_ | cold | lz4 | 1910 | 925 | 955 | 51% | 1247 | 596 | 36 |
| 1 kB | ydoc_ | reuse | off | 2749 | 898 | 1818 | 67% | 1709 | 970 | 36 |
| 1 kB | ydoc_ | reuse | lz4 | 1953 | 832 | 1091 | 57% | 1262 | 624 | 36 |
| 1 kB | ydoc_ | reuse | pglz | 1844 | 890 | 923 | 51% | 1118 | 659 | 36 |
| 5 kB | plain text (lz4) | cold | off | 5292 | 5028 | 226 | 4% | 5020 | 200 | 34 |
| 5 kB | plain text (lz4) | warm | off | 5102 | 5064 | 0 | 0% | 4832 | 198 | 34 |
| 5 kB | plain text (lz4) | cold | pglz | 5465 | 5089 | 337 | 6% | 5193 | 199 | 34 |
| 5 kB | plain text (lz4) | cold | lz4 | 5510 | 5120 | 350 | 6% | 5236 | 201 | 34 |
| 5 kB | plain text (lz4) | reuse | off | 5420 | 5152 | 230 | 4% | 5149 | 199 | 34 |
| 5 kB | plain text (lz4) | reuse | lz4 | 5444 | 5177 | 228 | 4% | 5171 | 200 | 34 |
| 5 kB | plain text (lz4) | reuse | pglz | 5479 | 5209 | 230 | 4% | 5206 | 200 | 34 |
| 5 kB | plain text (pglz) | cold | off | 4745 | 4498 | 210 | 4% | 4535 | 139 | 34 |
| 5 kB | plain text (pglz) | warm | off | 4639 | 4602 | 0 | 0% | 4425 | 143 | 34 |
| 5 kB | plain text (pglz) | cold | pglz | 4990 | 4724 | 227 | 5% | 4764 | 153 | 34 |
| 5 kB | plain text (pglz) | cold | lz4 | 5221 | 4921 | 261 | 5% | 4985 | 163 | 34 |
| 5 kB | plain text (pglz) | reuse | off | 5472 | 5206 | 226 | 4% | 5221 | 177 | 34 |
| 5 kB | plain text (pglz) | reuse | lz4 | 5712 | 5453 | 217 | 4% | 5453 | 184 | 34 |
| 5 kB | plain text (pglz) | reuse | pglz | 5966 | 5684 | 240 | 4% | 5700 | 190 | 34 |
| 5 kB | yseq_ (lz4) | cold | off | 7118 | 6777 | 293 | 4% | 6813 | 223 | 34 |
| 5 kB | yseq_ (lz4) | warm | off | 7449 | 7401 | 0 | 0% | 7104 | 263 | 34 |
| 5 kB | yseq_ (lz4) | cold | pglz | 8484 | 7928 | 504 | 6% | 8131 | 267 | 34 |
| 5 kB | yseq_ (lz4) | cold | lz4 | 9114 | 8462 | 596 | 7% | 8756 | 268 | 34 |
| 5 kB | yseq_ (lz4) | reuse | off | 9477 | 9021 | 400 | 4% | 9091 | 295 | 34 |
| 5 kB | yseq_ (lz4) | reuse | lz4 | 10065 | 9592 | 414 | 4% | 9643 | 328 | 34 |
| 5 kB | yseq_ (lz4) | reuse | pglz | 10600 | 10074 | 465 | 4% | 10172 | 332 | 34 |
| 5 kB | yseq_ (pglz) | cold | off | 6271 | 5965 | 261 | 4% | 5991 | 202 | 34 |
| 5 kB | yseq_ (pglz) | warm | off | 6408 | 6363 | 0 | 0% | 6131 | 198 | 34 |
| 5 kB | yseq_ (pglz) | cold | pglz | 7144 | 6794 | 301 | 4% | 6840 | 222 | 34 |
| 5 kB | yseq_ (pglz) | cold | lz4 | 7694 | 7205 | 440 | 6% | 7352 | 260 | 34 |
| 5 kB | yseq_ (pglz) | reuse | off | 7978 | 7592 | 336 | 4% | 7629 | 265 | 34 |
| 5 kB | yseq_ (pglz) | reuse | lz4 | 8327 | 7928 | 349 | 4% | 7977 | 266 | 34 |
| 5 kB | yseq_ (pglz) | reuse | pglz | 8675 | 8257 | 366 | 4% | 8324 | 265 | 34 |
| 5 kB | ydoc_ | cold | off | 2390 | 1260 | 1096 | 47% | 1555 | 764 | 36 |
| 5 kB | ydoc_ | warm | off | 1117 | 1068 | 19 | 2% | 752 | 299 | 36 |
| 5 kB | ydoc_ | cold | pglz | 1971 | 1065 | 873 | 45% | 1341 | 561 | 36 |
| 5 kB | ydoc_ | cold | lz4 | 2354 | 1084 | 1237 | 53% | 1602 | 682 | 36 |
| 5 kB | ydoc_ | reuse | off | 3343 | 1102 | 2204 | 67% | 2119 | 1150 | 36 |
| 5 kB | ydoc_ | reuse | lz4 | 2435 | 1007 | 1392 | 58% | 1638 | 725 | 36 |
| 5 kB | ydoc_ | reuse | pglz | 2302 | 1011 | 1256 | 55% | 1510 | 721 | 36 |
| 20 kB | plain text (lz4) | cold | off | 16504 | 15683 | 734 | 4% | 15875 | 508 | 34 |
| 20 kB | plain text (lz4) | warm | off | 15826 | 15741 | 0 | 0% | 15196 | 511 | 34 |
| 20 kB | plain text (lz4) | cold | pglz | 16727 | 15794 | 845 | 5% | 16085 | 520 | 34 |
| 20 kB | plain text (lz4) | cold | lz4 | 16808 | 15843 | 877 | 5% | 16160 | 526 | 34 |
| 20 kB | plain text (lz4) | reuse | off | 16704 | 15886 | 732 | 4% | 16056 | 527 | 34 |
| 20 kB | plain text (lz4) | reuse | lz4 | 16751 | 15935 | 729 | 4% | 16100 | 530 | 34 |
| 20 kB | plain text (lz4) | reuse | pglz | 16792 | 15970 | 734 | 4% | 16139 | 530 | 34 |
| 20 kB | plain text (pglz) | cold | off | 15247 | 14486 | 679 | 4% | 14664 | 467 | 34 |
| 20 kB | plain text (pglz) | warm | off | 14614 | 14534 | 0 | 0% | 14037 | 463 | 34 |
| 20 kB | plain text (pglz) | cold | pglz | 15564 | 14556 | 925 | 6% | 14982 | 466 | 34 |
| 20 kB | plain text (pglz) | cold | lz4 | 15525 | 14604 | 839 | 5% | 14944 | 465 | 34 |
| 20 kB | plain text (pglz) | reuse | off | 15408 | 14649 | 677 | 4% | 14827 | 465 | 34 |
| 20 kB | plain text (pglz) | reuse | lz4 | 15448 | 14692 | 675 | 4% | 14866 | 466 | 34 |
| 20 kB | plain text (pglz) | reuse | pglz | 15502 | 14739 | 680 | 4% | 14920 | 465 | 34 |
| 20 kB | yseq_ (lz4) | cold | off | 18459 | 17570 | 796 | 4% | 17788 | 544 | 34 |
| 20 kB | yseq_ (lz4) | warm | off | 18419 | 18322 | 0 | 0% | 17697 | 591 | 34 |
| 20 kB | yseq_ (lz4) | cold | pglz | 19942 | 18890 | 950 | 5% | 19210 | 596 | 34 |
| 20 kB | yseq_ (lz4) | cold | lz4 | 20513 | 19483 | 925 | 5% | 19773 | 601 | 34 |
| 20 kB | yseq_ (lz4) | reuse | off | 21144 | 20119 | 918 | 4% | 20363 | 640 | 34 |
| 20 kB | yseq_ (lz4) | reuse | lz4 | 21736 | 20701 | 926 | 4% | 20934 | 660 | 34 |
| 20 kB | yseq_ (lz4) | reuse | pglz | 22371 | 21290 | 969 | 4% | 21562 | 663 | 34 |
| 20 kB | yseq_ (pglz) | cold | off | 16883 | 16066 | 729 | 4% | 16233 | 527 | 34 |
| 20 kB | yseq_ (pglz) | warm | off | 16587 | 16500 | 0 | 0% | 15938 | 528 | 34 |
| 20 kB | yseq_ (pglz) | cold | pglz | 17757 | 16896 | 771 | 4% | 17102 | 531 | 34 |
| 20 kB | yseq_ (pglz) | cold | lz4 | 18193 | 17313 | 788 | 4% | 17534 | 533 | 34 |
| 20 kB | yseq_ (pglz) | reuse | off | 18729 | 17819 | 813 | 4% | 18034 | 564 | 34 |
| 20 kB | yseq_ (pglz) | reuse | lz4 | 19205 | 18277 | 830 | 4% | 18479 | 594 | 34 |
| 20 kB | yseq_ (pglz) | reuse | pglz | 19640 | 18688 | 852 | 4% | 18911 | 596 | 34 |
| 20 kB | ydoc_ | cold | off | 3461 | 1280 | 2142 | 63% | 2510 | 876 | 36 |
| 20 kB | ydoc_ | warm | off | 1412 | 1216 | 164 | 12% | 1012 | 331 | 36 |
| 20 kB | ydoc_ | cold | pglz | 2686 | 1125 | 1526 | 58% | 2027 | 587 | 36 |
| 20 kB | ydoc_ | cold | lz4 | 3172 | 1210 | 1925 | 61% | 2309 | 790 | 36 |
| 20 kB | ydoc_ | reuse | off | 4497 | 1161 | 3294 | 74% | 3113 | 1306 | 36 |
| 20 kB | ydoc_ | reuse | lz4 | 3337 | 1120 | 2179 | 66% | 2418 | 844 | 36 |
| 20 kB | ydoc_ | reuse | pglz | 3116 | 1103 | 1975 | 64% | 2232 | 809 | 36 |
| 100 kB | plain text (lz4) | cold | off | 76648 | 72907 | 3399 | 4% | 74040 | 2232 | 34 |
| 100 kB | plain text (lz4) | warm | off | 73314 | 72983 | 0 | 0% | 70716 | 2233 | 34 |
| 100 kB | plain text (lz4) | cold | pglz | 76883 | 73023 | 3517 | 5% | 74268 | 2238 | 34 |
| 100 kB | plain text (lz4) | cold | lz4 | 76890 | 73103 | 3445 | 4% | 74276 | 2237 | 34 |
| 100 kB | plain text (lz4) | reuse | off | 76918 | 73163 | 3412 | 4% | 74306 | 2235 | 34 |
| 100 kB | plain text (lz4) | reuse | lz4 | 76943 | 73231 | 3369 | 4% | 74327 | 2238 | 34 |
| 100 kB | plain text (lz4) | reuse | pglz | 77049 | 73289 | 3416 | 4% | 74431 | 2240 | 34 |
| 100 kB | plain text (pglz) | cold | off | 70964 | 67493 | 3151 | 4% | 68568 | 2042 | 34 |
| 100 kB | plain text (pglz) | warm | off | 67855 | 67545 | 0 | 0% | 65471 | 2041 | 34 |
| 100 kB | plain text (pglz) | cold | pglz | 71087 | 67606 | 3160 | 4% | 68686 | 2047 | 34 |
| 100 kB | plain text (pglz) | cold | lz4 | 71107 | 67641 | 3146 | 4% | 68709 | 2044 | 34 |
| 100 kB | plain text (pglz) | reuse | off | 71161 | 67681 | 3159 | 4% | 68759 | 2048 | 34 |
| 100 kB | plain text (pglz) | reuse | lz4 | 71206 | 67739 | 3147 | 4% | 68800 | 2052 | 34 |
| 100 kB | plain text (pglz) | reuse | pglz | 71277 | 67797 | 3159 | 4% | 68867 | 2055 | 34 |
| 100 kB | yseq_ (lz4) | cold | off | 78733 | 74904 | 3477 | 4% | 76041 | 2306 | 34 |
| 100 kB | yseq_ (lz4) | warm | off | 75978 | 75634 | 0 | 0% | 73258 | 2342 | 34 |
| 100 kB | yseq_ (lz4) | cold | pglz | 80270 | 76271 | 3640 | 5% | 77525 | 2352 | 34 |
| 100 kB | yseq_ (lz4) | cold | lz4 | 80892 | 76978 | 3554 | 4% | 78119 | 2379 | 34 |
| 100 kB | yseq_ (lz4) | reuse | off | 81591 | 77621 | 3607 | 4% | 78802 | 2393 | 34 |
| 100 kB | yseq_ (lz4) | reuse | lz4 | 82204 | 78257 | 3581 | 4% | 79404 | 2400 | 34 |
| 100 kB | yseq_ (lz4) | reuse | pglz | 82978 | 78943 | 3664 | 4% | 80153 | 2421 | 34 |
| 100 kB | yseq_ (pglz) | cold | off | 72724 | 69184 | 3215 | 4% | 70223 | 2142 | 34 |
| 100 kB | yseq_ (pglz) | warm | off | 69970 | 69655 | 0 | 0% | 67481 | 2139 | 34 |
| 100 kB | yseq_ (pglz) | cold | pglz | 74152 | 70177 | 3644 | 5% | 71621 | 2166 | 34 |
| 100 kB | yseq_ (pglz) | cold | lz4 | 76010 | 70611 | 5061 | 7% | 73452 | 2186 | 34 |
| 100 kB | yseq_ (pglz) | reuse | off | 74789 | 71141 | 3314 | 4% | 72234 | 2187 | 34 |
| 100 kB | yseq_ (pglz) | reuse | lz4 | 75260 | 71607 | 3315 | 4% | 72697 | 2191 | 34 |
| 100 kB | yseq_ (pglz) | reuse | pglz | 75750 | 72058 | 3352 | 4% | 73174 | 2201 | 34 |
| 100 kB | ydoc_ | cold | off | 8341 | 1347 | 6937 | 84% | 6516 | 1732 | 36 |
| 100 kB | ydoc_ | warm | off | 2656 | 1327 | 1292 | 49% | 2195 | 388 | 36 |
| 100 kB | ydoc_ | cold | pglz | 4171 | 1210 | 2919 | 71% | 3283 | 810 | 36 |
| 100 kB | ydoc_ | cold | lz4 | 4562 | 1183 | 3337 | 74% | 3563 | 921 | 36 |
| 100 kB | ydoc_ | reuse | off | 7368 | 1147 | 6169 | 84% | 5507 | 1773 | 36 |
| 100 kB | ydoc_ | reuse | lz4 | 5415 | 1229 | 4140 | 77% | 4212 | 1121 | 36 |
| 100 kB | ydoc_ | reuse | pglz | 5042 | 1240 | 3757 | 75% | 3880 | 1080 | 36 |

