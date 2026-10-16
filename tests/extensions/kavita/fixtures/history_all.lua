--[[--
样本 fixture：`GET /api/Stats/reading-history` 全量实测响应（2026-10-16，Kavita 0.9.1.4）的
精简版，只留聚合用到的字段（seriesId / localDate / startTimeUtc / chapters[]），共 316 条会话 /
60 个系列 / 2 页。

数值逐条未改；对账基线 = research-kavita-stats-pull.md §2（逐日时长 / 页数）与 §4（Σ=60,238s /
1,406 页 / 起点 2026-09-18）。来源完整响应：/tmp/opencode/kavita/live/history-all-sep-oct.json。

@module tests.extensions.kavita.fixtures.history_all
--]]
return {
    { seriesId = 7606, localDate = "2026-10-16T00:00:00", startTimeUtc = "2026-10-15T23:51:47.4527045", chapters = {
            { chapterId = 11501, startTimeUtc = "2026-10-15T23:51:47.4527045", durationSeconds = 220, pagesRead = 6 } } },
    { seriesId = 7453, localDate = "2026-10-15T00:00:00", startTimeUtc = "2026-10-15T13:49:02.6722926", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-15T13:49:02.6722926", durationSeconds = 845, pagesRead = 0 } } },
    { seriesId = 7606, localDate = "2026-10-15T00:00:00", startTimeUtc = "2026-10-15T13:41:03.9585123", chapters = {
            { chapterId = 11501, startTimeUtc = "2026-10-15T13:41:03.9585123", durationSeconds = 469, pagesRead = 6 } } },
    { seriesId = 7606, localDate = "2026-10-15T00:00:00", startTimeUtc = "2026-10-15T12:18:53.1535569", chapters = {
            { chapterId = 11501, startTimeUtc = "2026-10-15T12:18:53.1535569", durationSeconds = 163, pagesRead = 7 } } },
    { seriesId = 7453, localDate = "2026-10-15T00:00:00", startTimeUtc = "2026-10-15T11:51:10.7006183", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-15T11:51:10.7006183", durationSeconds = 638, pagesRead = 0 } } },
    { seriesId = 9249, localDate = "2026-10-15T00:00:00", startTimeUtc = "2026-10-15T11:40:49.4449693", chapters = {
            { chapterId = 13493, startTimeUtc = "2026-10-15T11:40:49.4449693", durationSeconds = 335, pagesRead = 1 } } },
    { seriesId = 10634, localDate = "2026-10-15T00:00:00", startTimeUtc = "2026-10-15T11:35:04.1639136", chapters = {
            { chapterId = 17863, startTimeUtc = "2026-10-15T11:38:58.0370869", durationSeconds = 81, pagesRead = 15 },
            { chapterId = 17868, startTimeUtc = "2026-10-15T11:35:04.1639136", durationSeconds = 210, pagesRead = 29 } } },
    { seriesId = 7453, localDate = "2026-10-15T00:00:00", startTimeUtc = "2026-10-15T11:14:33.5066159", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-15T11:14:33.5066159", durationSeconds = 436, pagesRead = 0 } } },
    { seriesId = 10634, localDate = "2026-10-15T00:00:00", startTimeUtc = "2026-10-15T11:04:40.7474367", chapters = {
            { chapterId = 17868, startTimeUtc = "2026-10-15T11:04:40.7474367", durationSeconds = 321, pagesRead = 44 } } },
    { seriesId = 7453, localDate = "2026-10-15T00:00:00", startTimeUtc = "2026-10-15T08:01:09.6078347", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-15T08:01:09.6078347", durationSeconds = 33, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-15T00:00:00", startTimeUtc = "2026-10-15T07:20:02.0863122", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-15T07:20:02.0863122", durationSeconds = 156, pagesRead = 15 } } },
    { seriesId = 7453, localDate = "2026-10-15T00:00:00", startTimeUtc = "2026-10-15T04:38:27.7268649", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-15T04:38:27.7268649", durationSeconds = 462, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-15T00:00:00", startTimeUtc = "2026-10-15T03:25:22.1307379", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-15T03:25:22.1307379", durationSeconds = 266, pagesRead = 1 } } },
    { seriesId = 7453, localDate = "2026-10-15T00:00:00", startTimeUtc = "2026-10-15T02:59:07.9600274", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-15T02:59:07.9600274", durationSeconds = 126, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-14T00:00:00", startTimeUtc = "2026-10-14T14:50:29.2326588", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-14T14:50:29.2326588", durationSeconds = 329, pagesRead = 0 } } },
    { seriesId = 10634, localDate = "2026-10-14T00:00:00", startTimeUtc = "2026-10-14T14:38:39.3797696", chapters = {
            { chapterId = 17868, startTimeUtc = "2026-10-14T14:38:39.3797696", durationSeconds = 481, pagesRead = 32 } } },
    { seriesId = 10634, localDate = "2026-10-14T00:00:00", startTimeUtc = "2026-10-14T14:08:54.1661113", chapters = {
            { chapterId = 17868, startTimeUtc = "2026-10-14T14:08:54.1661113", durationSeconds = 309, pagesRead = 27 } } },
    { seriesId = 7453, localDate = "2026-10-14T00:00:00", startTimeUtc = "2026-10-14T13:55:48.5704762", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-14T13:55:48.5704762", durationSeconds = 716, pagesRead = 0 } } },
    { seriesId = 9249, localDate = "2026-10-14T00:00:00", startTimeUtc = "2026-10-14T13:49:23.172248", chapters = {
            { chapterId = 13493, startTimeUtc = "2026-10-14T13:49:23.172248", durationSeconds = 305, pagesRead = 6 } } },
    { seriesId = 10634, localDate = "2026-10-14T00:00:00", startTimeUtc = "2026-10-14T13:03:43.5815681", chapters = {
            { chapterId = 17868, startTimeUtc = "2026-10-14T13:03:43.5815681", durationSeconds = 22, pagesRead = 3 } } },
    { seriesId = 7453, localDate = "2026-10-14T00:00:00", startTimeUtc = "2026-10-14T12:59:54.4012612", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-14T12:59:54.4012612", durationSeconds = 210, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-14T00:00:00", startTimeUtc = "2026-10-14T12:32:09.2873459", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-14T12:32:09.2873459", durationSeconds = 354, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-14T00:00:00", startTimeUtc = "2026-10-14T10:50:12.8325335", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-14T10:50:12.8325335", durationSeconds = 427, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-14T00:00:00", startTimeUtc = "2026-10-14T09:55:45.2531997", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-14T09:55:45.2531997", durationSeconds = 229, pagesRead = 0 } } },
    { seriesId = 7460, localDate = "2026-10-14T00:00:00", startTimeUtc = "2026-10-14T09:17:05.53145", chapters = {
            { chapterId = 11285, startTimeUtc = "2026-10-14T09:17:05.53145", durationSeconds = 433, pagesRead = 0 } } },
    { seriesId = 7606, localDate = "2026-10-14T00:00:00", startTimeUtc = "2026-10-14T09:13:54.1770611", chapters = {
            { chapterId = 11501, startTimeUtc = "2026-10-14T09:13:54.1770611", durationSeconds = 141, pagesRead = 3 } } },
    { seriesId = 7606, localDate = "2026-10-14T00:00:00", startTimeUtc = "2026-10-14T08:31:01.497007", chapters = {
            { chapterId = 11501, startTimeUtc = "2026-10-14T08:31:01.497007", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-14T00:00:00", startTimeUtc = "2026-10-14T08:18:25.5482677", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-14T08:18:25.5482677", durationSeconds = 631, pagesRead = 0 } } },
    { seriesId = 7540, localDate = "2026-10-14T00:00:00", startTimeUtc = "2026-10-14T07:55:05.3240629", chapters = {
            { chapterId = 13394, startTimeUtc = "2026-10-14T07:55:05.3240629", durationSeconds = 82, pagesRead = 0 } } },
    { seriesId = 10705, localDate = "2026-10-14T00:00:00", startTimeUtc = "2026-10-14T07:38:45.2095335", chapters = {
            { chapterId = 18930, startTimeUtc = "2026-10-14T07:38:45.2095335", durationSeconds = 206, pagesRead = 3 } } },
    { seriesId = 7540, localDate = "2026-10-14T00:00:00", startTimeUtc = "2026-10-14T07:34:26.9247375", chapters = {
            { chapterId = 13394, startTimeUtc = "2026-10-14T07:34:26.9247375", durationSeconds = 83, pagesRead = 5 } } },
    { seriesId = 10720, localDate = "2026-10-14T00:00:00", startTimeUtc = "2026-10-14T07:16:16.0691328", chapters = {
            { chapterId = 18951, startTimeUtc = "2026-10-14T07:16:16.0691328", durationSeconds = 72, pagesRead = 10 } } },
    { seriesId = 8661, localDate = "2026-10-14T00:00:00", startTimeUtc = "2026-10-14T07:14:59.4980606", chapters = {
            { chapterId = 12763, startTimeUtc = "2026-10-14T07:14:59.4980606", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7805, localDate = "2026-10-14T00:00:00", startTimeUtc = "2026-10-14T07:14:45.0436933", chapters = {
            { chapterId = 11791, startTimeUtc = "2026-10-14T07:14:45.0436933", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7540, localDate = "2026-10-14T00:00:00", startTimeUtc = "2026-10-14T07:14:08.0963104", chapters = {
            { chapterId = 13394, startTimeUtc = "2026-10-14T07:14:08.0963104", durationSeconds = 71, pagesRead = 2 } } },
    { seriesId = 7606, localDate = "2026-10-14T00:00:00", startTimeUtc = "2026-10-14T06:46:46.3439122", chapters = {
            { chapterId = 11501, startTimeUtc = "2026-10-14T07:07:38.102712", durationSeconds = 0, pagesRead = 0 },
            { chapterId = 11501, startTimeUtc = "2026-10-14T06:46:46.3439122", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7460, localDate = "2026-10-14T00:00:00", startTimeUtc = "2026-10-14T06:54:53.1919748", chapters = {
            { chapterId = 11285, startTimeUtc = "2026-10-14T07:06:44.0374852", durationSeconds = 21, pagesRead = 24 },
            { chapterId = 11285, startTimeUtc = "2026-10-14T06:54:53.1919748", durationSeconds = 48, pagesRead = 1 } } },
    { seriesId = 7453, localDate = "2026-10-14T00:00:00", startTimeUtc = "2026-10-14T06:35:44.8950968", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-14T06:56:37.9521487", durationSeconds = 597, pagesRead = 5 },
            { chapterId = 11273, startTimeUtc = "2026-10-14T06:35:44.8950968", durationSeconds = 529, pagesRead = -6 } } },
    { seriesId = 7453, localDate = "2026-10-14T00:00:00", startTimeUtc = "2026-10-14T06:12:27.3026502", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-14T06:12:27.3026502", durationSeconds = 686, pagesRead = 1 } } },
    { seriesId = 7460, localDate = "2026-10-14T00:00:00", startTimeUtc = "2026-10-14T06:02:06.7713486", chapters = {
            { chapterId = 11285, startTimeUtc = "2026-10-14T06:02:06.7713486", durationSeconds = 647, pagesRead = 0 } } },
    { seriesId = 7460, localDate = "2026-10-14T00:00:00", startTimeUtc = "2026-10-14T05:48:30.213286", chapters = {
            { chapterId = 11285, startTimeUtc = "2026-10-14T05:48:30.213286", durationSeconds = 113, pagesRead = 1 } } },
    { seriesId = 7606, localDate = "2026-10-14T00:00:00", startTimeUtc = "2026-10-14T05:47:30.9663527", chapters = {
            { chapterId = 11501, startTimeUtc = "2026-10-14T05:47:30.9663527", durationSeconds = 40, pagesRead = 3 } } },
    { seriesId = 7453, localDate = "2026-10-14T00:00:00", startTimeUtc = "2026-10-14T05:35:38.8926445", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-14T05:35:38.8926445", durationSeconds = 674, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-14T00:00:00", startTimeUtc = "2026-10-14T03:36:59.7411875", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-14T03:36:59.7411875", durationSeconds = 1352, pagesRead = 0 } } },
    { seriesId = 7460, localDate = "2026-10-14T00:00:00", startTimeUtc = "2026-10-14T03:28:46.1491425", chapters = {
            { chapterId = 11285, startTimeUtc = "2026-10-14T03:28:46.1491425", durationSeconds = 794, pagesRead = -1 } } },
    { seriesId = 7606, localDate = "2026-10-14T00:00:00", startTimeUtc = "2026-10-14T03:16:21.8058422", chapters = {
            { chapterId = 11501, startTimeUtc = "2026-10-14T03:16:21.8058422", durationSeconds = 1063, pagesRead = 1 } } },
    { seriesId = 7606, localDate = "2026-10-14T00:00:00", startTimeUtc = "2026-10-14T01:55:37.5163534", chapters = {
            { chapterId = 11501, startTimeUtc = "2026-10-14T01:55:37.5163534", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 10004, localDate = "2026-10-14T00:00:00", startTimeUtc = "2026-10-14T01:49:18.2803981", chapters = {
            { chapterId = 14594, startTimeUtc = "2026-10-14T01:49:18.2803981", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-14T00:00:00", startTimeUtc = "2026-10-14T01:39:31.4453653", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-14T01:39:31.4453653", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 10634, localDate = "2026-10-13T00:00:00", startTimeUtc = "2026-10-13T14:57:39.6850524", chapters = {
            { chapterId = 17868, startTimeUtc = "2026-10-13T14:57:39.6850524", durationSeconds = 296, pagesRead = 43 } } },
    { seriesId = 7453, localDate = "2026-10-13T00:00:00", startTimeUtc = "2026-10-13T14:56:50.7578846", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-13T14:56:50.7578846", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 10634, localDate = "2026-10-13T00:00:00", startTimeUtc = "2026-10-13T14:36:12.2101045", chapters = {
            { chapterId = 17868, startTimeUtc = "2026-10-13T14:42:41.461277", durationSeconds = 73, pagesRead = 17 },
            { chapterId = 17861, startTimeUtc = "2026-10-13T14:36:12.2101045", durationSeconds = 382, pagesRead = 50 } } },
    { seriesId = 10634, localDate = "2026-10-13T00:00:00", startTimeUtc = "2026-10-13T13:30:56.9584871", chapters = {
            { chapterId = 17861, startTimeUtc = "2026-10-13T13:30:56.9584871", durationSeconds = 965, pagesRead = 35 } } },
    { seriesId = 7453, localDate = "2026-10-13T00:00:00", startTimeUtc = "2026-10-13T12:50:13.6195947", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-13T12:50:13.6195947", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 10634, localDate = "2026-10-13T00:00:00", startTimeUtc = "2026-10-13T11:07:48.1054905", chapters = {
            { chapterId = 17861, startTimeUtc = "2026-10-13T11:07:48.1054905", durationSeconds = 1557, pagesRead = 87 } } },
    { seriesId = 7453, localDate = "2026-10-13T00:00:00", startTimeUtc = "2026-10-13T10:49:24.2700176", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-13T10:49:24.2700176", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 10634, localDate = "2026-10-13T00:00:00", startTimeUtc = "2026-10-13T10:33:26.9620773", chapters = {
            { chapterId = 17861, startTimeUtc = "2026-10-13T10:33:26.9620773", durationSeconds = 85, pagesRead = 9 } } },
    { seriesId = 7453, localDate = "2026-10-13T00:00:00", startTimeUtc = "2026-10-13T09:19:44.4142404", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-13T09:19:44.4142404", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7606, localDate = "2026-10-13T00:00:00", startTimeUtc = "2026-10-13T08:41:22.7503239", chapters = {
            { chapterId = 11501, startTimeUtc = "2026-10-13T08:41:22.7503239", durationSeconds = 177, pagesRead = 3 } } },
    { seriesId = 7453, localDate = "2026-10-13T00:00:00", startTimeUtc = "2026-10-13T07:17:51.0855549", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-13T07:17:51.0855549", durationSeconds = 31, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-13T00:00:00", startTimeUtc = "2026-10-13T06:23:56.2429684", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-13T06:23:56.2429684", durationSeconds = 948, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-13T00:00:00", startTimeUtc = "2026-10-13T04:44:11.1456271", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-13T04:44:11.1456271", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-13T00:00:00", startTimeUtc = "2026-10-13T04:04:52.1419963", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-13T04:04:52.1419963", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 10634, localDate = "2026-10-12T00:00:00", startTimeUtc = "2026-10-12T13:41:25.4902953", chapters = {
            { chapterId = 17861, startTimeUtc = "2026-10-12T13:41:25.4902953", durationSeconds = 77, pagesRead = 5 } } },
    { seriesId = 10634, localDate = "2026-10-12T00:00:00", startTimeUtc = "2026-10-12T04:30:51.522376", chapters = {
            { chapterId = 17861, startTimeUtc = "2026-10-12T04:30:51.522376", durationSeconds = 26, pagesRead = 4 } } },
    { seriesId = 7453, localDate = "2026-10-12T00:00:00", startTimeUtc = "2026-10-12T03:52:47.3926019", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-12T03:52:47.3926019", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 10634, localDate = "2026-10-12T00:00:00", startTimeUtc = "2026-10-12T02:50:17.2681685", chapters = {
            { chapterId = 17861, startTimeUtc = "2026-10-12T02:59:07.2940778", durationSeconds = 505, pagesRead = 5 },
            { chapterId = 17855, startTimeUtc = "2026-10-12T02:50:17.2681685", durationSeconds = 518, pagesRead = 12 } } },
    { seriesId = 10634, localDate = "2026-10-12T00:00:00", startTimeUtc = "2026-10-12T02:26:17.4191481", chapters = {
            { chapterId = 17855, startTimeUtc = "2026-10-12T02:26:17.4191481", durationSeconds = 332, pagesRead = 27 } } },
    { seriesId = 10600, localDate = "2026-10-12T00:00:00", startTimeUtc = "2026-10-11T16:06:22.9336343", chapters = {
            { chapterId = 17139, startTimeUtc = "2026-10-11T16:06:22.9336343", durationSeconds = 34, pagesRead = 11 } } },
    { seriesId = 10634, localDate = "2026-10-12T00:00:00", startTimeUtc = "2026-10-11T16:00:00.7226412", chapters = {
            { chapterId = 17855, startTimeUtc = "2026-10-11T16:00:00.7226412", durationSeconds = 311, pagesRead = 39 } } },
    { seriesId = 10634, localDate = "2026-10-11T00:00:00", startTimeUtc = "2026-10-11T15:54:42.9913657", chapters = {
            { chapterId = 17855, startTimeUtc = "2026-10-11T15:54:42.9913657", durationSeconds = 137, pagesRead = 26 } } },
    { seriesId = 7453, localDate = "2026-10-11T00:00:00", startTimeUtc = "2026-10-11T15:16:45.9848037", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-11T15:16:45.9848037", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-11T00:00:00", startTimeUtc = "2026-10-11T14:54:13.613368", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-11T14:54:13.613368", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-11T00:00:00", startTimeUtc = "2026-10-11T14:35:43.0809755", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-11T14:35:43.0809755", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-11T00:00:00", startTimeUtc = "2026-10-11T12:58:29.291105", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-11T12:58:29.291105", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-11T00:00:00", startTimeUtc = "2026-10-11T11:00:42.6215043", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-11T11:00:42.6215043", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-11T00:00:00", startTimeUtc = "2026-10-11T04:17:28.3592015", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-11T04:17:28.3592015", durationSeconds = 512, pagesRead = 0 } } },
    { seriesId = 7606, localDate = "2026-10-11T00:00:00", startTimeUtc = "2026-10-11T02:53:45.4676925", chapters = {
            { chapterId = 11501, startTimeUtc = "2026-10-11T02:53:45.4676925", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 9249, localDate = "2026-10-10T00:00:00", startTimeUtc = "2026-10-10T15:00:59.375396", chapters = {
            { chapterId = 13493, startTimeUtc = "2026-10-10T15:00:59.375396", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 9249, localDate = "2026-10-10T00:00:00", startTimeUtc = "2026-10-10T09:37:25.4148239", chapters = {
            { chapterId = 13493, startTimeUtc = "2026-10-10T09:37:25.4148239", durationSeconds = 2, pagesRead = 0 } } },
    { seriesId = 9249, localDate = "2026-10-10T00:00:00", startTimeUtc = "2026-10-10T08:58:13.142957", chapters = {
            { chapterId = 13493, startTimeUtc = "2026-10-10T08:58:13.142957", durationSeconds = 9, pagesRead = 0 } } },
    { seriesId = 9249, localDate = "2026-10-10T00:00:00", startTimeUtc = "2026-10-10T08:15:36.7468877", chapters = {
            { chapterId = 13493, startTimeUtc = "2026-10-10T08:15:36.7468877", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 9249, localDate = "2026-10-10T00:00:00", startTimeUtc = "2026-10-10T07:52:18.8289612", chapters = {
            { chapterId = 13493, startTimeUtc = "2026-10-10T07:52:18.8289612", durationSeconds = 164, pagesRead = 0 } } },
    { seriesId = 9249, localDate = "2026-10-10T00:00:00", startTimeUtc = "2026-10-10T07:10:45.3655221", chapters = {
            { chapterId = 13493, startTimeUtc = "2026-10-10T07:10:45.3655221", durationSeconds = 33, pagesRead = 1 } } },
    { seriesId = 7453, localDate = "2026-10-10T00:00:00", startTimeUtc = "2026-10-10T04:44:42.7023417", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-10T04:44:42.7023417", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-10T00:00:00", startTimeUtc = "2026-10-10T03:55:35.74839", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-10T03:55:35.74839", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7606, localDate = "2026-10-10T00:00:00", startTimeUtc = "2026-10-10T03:41:12.3904529", chapters = {
            { chapterId = 11501, startTimeUtc = "2026-10-10T03:41:12.3904529", durationSeconds = 12, pagesRead = 2 } } },
    { seriesId = 7453, localDate = "2026-10-10T00:00:00", startTimeUtc = "2026-10-10T03:39:55.2030981", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-10T03:39:55.2030981", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7606, localDate = "2026-10-10T00:00:00", startTimeUtc = "2026-10-10T02:29:21.0392738", chapters = {
            { chapterId = 11501, startTimeUtc = "2026-10-10T02:29:21.0392738", durationSeconds = 40, pagesRead = 2 } } },
    { seriesId = 7606, localDate = "2026-10-10T00:00:00", startTimeUtc = "2026-10-10T02:12:18.2048535", chapters = {
            { chapterId = 11501, startTimeUtc = "2026-10-10T02:12:18.2048535", durationSeconds = 53, pagesRead = 3 } } },
    { seriesId = 7606, localDate = "2026-10-10T00:00:00", startTimeUtc = "2026-10-10T01:55:30.4051153", chapters = {
            { chapterId = 11501, startTimeUtc = "2026-10-10T01:55:30.4051153", durationSeconds = 50, pagesRead = 2 } } },
    { seriesId = 7453, localDate = "2026-10-09T00:00:00", startTimeUtc = "2026-10-09T14:45:39.0731175", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-09T14:45:39.0731175", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7606, localDate = "2026-10-09T00:00:00", startTimeUtc = "2026-10-09T13:43:07.3149178", chapters = {
            { chapterId = 11501, startTimeUtc = "2026-10-09T13:43:07.3149178", durationSeconds = 5, pagesRead = 0 } } },
    { seriesId = 10735, localDate = "2026-10-09T00:00:00", startTimeUtc = "2026-10-09T13:32:16.6705302", chapters = {
            { chapterId = 18969, startTimeUtc = "2026-10-09T13:32:16.6705302", durationSeconds = 163, pagesRead = 5 } } },
    { seriesId = 10698, localDate = "2026-10-09T00:00:00", startTimeUtc = "2026-10-09T13:30:11.0145349", chapters = {
            { chapterId = 18923, startTimeUtc = "2026-10-09T13:30:11.0145349", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7606, localDate = "2026-10-09T00:00:00", startTimeUtc = "2026-10-09T13:17:56.7622935", chapters = {
            { chapterId = 11501, startTimeUtc = "2026-10-09T13:17:56.7622935", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7606, localDate = "2026-10-09T00:00:00", startTimeUtc = "2026-10-09T11:51:14.1858092", chapters = {
            { chapterId = 11501, startTimeUtc = "2026-10-09T11:51:14.1858092", durationSeconds = 7, pagesRead = 0 } } },
    { seriesId = 10732, localDate = "2026-10-09T00:00:00", startTimeUtc = "2026-10-09T11:20:33.6944863", chapters = {
            { chapterId = 18966, startTimeUtc = "2026-10-09T11:20:33.6944863", durationSeconds = 29, pagesRead = 21 } } },
    { seriesId = 10735, localDate = "2026-10-09T00:00:00", startTimeUtc = "2026-10-09T11:15:31.2028337", chapters = {
            { chapterId = 18969, startTimeUtc = "2026-10-09T11:15:31.2028337", durationSeconds = 80, pagesRead = 33 } } },
    { seriesId = 10724, localDate = "2026-10-09T00:00:00", startTimeUtc = "2026-10-09T11:12:30.4622536", chapters = {
            { chapterId = 18957, startTimeUtc = "2026-10-09T11:12:30.4622536", durationSeconds = 4, pagesRead = 0 } } },
    { seriesId = 7606, localDate = "2026-10-09T00:00:00", startTimeUtc = "2026-10-09T11:04:22.6125371", chapters = {
            { chapterId = 11501, startTimeUtc = "2026-10-09T11:04:22.6125371", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 10724, localDate = "2026-10-09T00:00:00", startTimeUtc = "2026-10-09T10:29:16.8959018", chapters = {
            { chapterId = 18957, startTimeUtc = "2026-10-09T10:29:16.8959018", durationSeconds = 7, pagesRead = 16 } } },
    { seriesId = 7606, localDate = "2026-10-09T00:00:00", startTimeUtc = "2026-10-09T09:51:43.6940126", chapters = {
            { chapterId = 11501, startTimeUtc = "2026-10-09T09:51:43.6940126", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 9249, localDate = "2026-10-09T00:00:00", startTimeUtc = "2026-10-09T09:34:29.5406473", chapters = {
            { chapterId = 13493, startTimeUtc = "2026-10-09T09:34:29.5406473", durationSeconds = 3, pagesRead = 0 } } },
    { seriesId = 7606, localDate = "2026-10-09T00:00:00", startTimeUtc = "2026-10-09T09:34:17.5161863", chapters = {
            { chapterId = 11501, startTimeUtc = "2026-10-09T09:34:17.5161863", durationSeconds = 5, pagesRead = 1 } } },
    { seriesId = 7606, localDate = "2026-10-09T00:00:00", startTimeUtc = "2026-10-09T09:10:02.1865718", chapters = {
            { chapterId = 11501, startTimeUtc = "2026-10-09T09:10:02.1865718", durationSeconds = 759, pagesRead = 11 } } },
    { seriesId = 10708, localDate = "2026-10-09T00:00:00", startTimeUtc = "2026-10-09T08:18:07.1620583", chapters = {
            { chapterId = 18933, startTimeUtc = "2026-10-09T08:18:07.1620583", durationSeconds = 15, pagesRead = 2 } } },
    { seriesId = 10707, localDate = "2026-10-09T00:00:00", startTimeUtc = "2026-10-09T07:55:45.2365064", chapters = {
            { chapterId = 18932, startTimeUtc = "2026-10-09T07:55:45.2365064", durationSeconds = 7, pagesRead = 4 } } },
    { seriesId = 7453, localDate = "2026-10-09T00:00:00", startTimeUtc = "2026-10-09T07:44:06.636679", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-09T07:44:06.636679", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-09T00:00:00", startTimeUtc = "2026-10-09T07:13:20.7857153", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-09T07:13:20.7857153", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-09T00:00:00", startTimeUtc = "2026-10-09T04:40:28.7189645", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-09T04:40:28.7189645", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-09T00:00:00", startTimeUtc = "2026-10-09T04:05:17.6951039", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-09T04:05:17.6951039", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 9249, localDate = "2026-10-09T00:00:00", startTimeUtc = "2026-10-09T03:03:56.2211648", chapters = {
            { chapterId = 13493, startTimeUtc = "2026-10-09T03:03:56.2211648", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 9292, localDate = "2026-10-09T00:00:00", startTimeUtc = "2026-10-09T01:10:42.7539032", chapters = {
            { chapterId = 13569, startTimeUtc = "2026-10-09T01:10:42.7539032", durationSeconds = 8, pagesRead = 0 } } },
    { seriesId = 9292, localDate = "2026-10-08T00:00:00", startTimeUtc = "2026-10-08T15:26:10.3634693", chapters = {
            { chapterId = 13569, startTimeUtc = "2026-10-08T15:26:10.3634693", durationSeconds = 15, pagesRead = 10 } } },
    { seriesId = 9249, localDate = "2026-10-08T00:00:00", startTimeUtc = "2026-10-08T15:12:20.8270779", chapters = {
            { chapterId = 13493, startTimeUtc = "2026-10-08T15:12:20.8270779", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-08T00:00:00", startTimeUtc = "2026-10-08T14:34:05.7981443", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-08T14:34:05.7981443", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-08T00:00:00", startTimeUtc = "2026-10-08T13:12:53.6969824", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-08T13:12:53.6969824", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 9249, localDate = "2026-10-08T00:00:00", startTimeUtc = "2026-10-08T11:49:28.3986198", chapters = {
            { chapterId = 13493, startTimeUtc = "2026-10-08T11:49:28.3986198", durationSeconds = 95, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-08T00:00:00", startTimeUtc = "2026-10-08T11:48:06.6315963", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-08T11:48:06.6315963", durationSeconds = 544, pagesRead = 0 } } },
    { seriesId = 7460, localDate = "2026-10-08T00:00:00", startTimeUtc = "2026-10-08T10:57:20.8373954", chapters = {
            { chapterId = 11285, startTimeUtc = "2026-10-08T11:15:47.102", durationSeconds = 1111, pagesRead = 0 },
            { chapterId = 11285, startTimeUtc = "2026-10-08T10:57:20.8373954", durationSeconds = 406, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-08T00:00:00", startTimeUtc = "2026-10-08T11:02:33.6484158", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-08T11:02:33.6484158", durationSeconds = 611, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-08T00:00:00", startTimeUtc = "2026-10-08T10:31:08.475182", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-08T10:31:08.475182", durationSeconds = 3, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-08T00:00:00", startTimeUtc = "2026-10-08T09:03:45.5309711", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-08T09:03:45.5309711", durationSeconds = 86, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-08T00:00:00", startTimeUtc = "2026-10-08T07:59:09.2881628", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-08T07:59:09.2881628", durationSeconds = 263, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-08T00:00:00", startTimeUtc = "2026-10-08T07:20:18.0105615", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-08T07:20:18.0105615", durationSeconds = 233, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-08T00:00:00", startTimeUtc = "2026-10-08T06:48:51.312417", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-08T06:48:51.312417", durationSeconds = 296, pagesRead = 0 } } },
    { seriesId = 7460, localDate = "2026-10-08T00:00:00", startTimeUtc = "2026-10-08T04:42:54.7579483", chapters = {
            { chapterId = 11285, startTimeUtc = "2026-10-08T04:42:54.7579483", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-08T00:00:00", startTimeUtc = "2026-10-08T04:05:45.0300961", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-08T04:05:45.0300961", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7540, localDate = "2026-10-08T00:00:00", startTimeUtc = "2026-10-08T02:52:33.5236184", chapters = {
            { chapterId = 13394, startTimeUtc = "2026-10-08T02:52:33.5236184", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7460, localDate = "2026-10-08T00:00:00", startTimeUtc = "2026-10-08T02:20:36.4169563", chapters = {
            { chapterId = 11285, startTimeUtc = "2026-10-08T02:20:36.4169563", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-07T00:00:00", startTimeUtc = "2026-10-07T13:44:15.125016", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-07T13:44:15.125016", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-07T00:00:00", startTimeUtc = "2026-10-07T09:45:01.0814021", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-07T09:45:01.0814021", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-07T00:00:00", startTimeUtc = "2026-10-07T05:19:38.9892914", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-07T05:19:38.9892914", durationSeconds = 503, pagesRead = 0 } } },
    { seriesId = 7460, localDate = "2026-10-06T00:00:00", startTimeUtc = "2026-10-06T13:00:26.371751", chapters = {
            { chapterId = 11285, startTimeUtc = "2026-10-06T13:00:26.371751", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7460, localDate = "2026-10-06T00:00:00", startTimeUtc = "2026-10-06T12:21:25.7149691", chapters = {
            { chapterId = 11285, startTimeUtc = "2026-10-06T12:21:25.7149691", durationSeconds = 489, pagesRead = 0 } } },
    { seriesId = 9249, localDate = "2026-10-06T00:00:00", startTimeUtc = "2026-10-06T12:07:54.0702478", chapters = {
            { chapterId = 13493, startTimeUtc = "2026-10-06T12:07:54.0702478", durationSeconds = 320, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-06T00:00:00", startTimeUtc = "2026-10-06T12:01:31.4949015", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-06T12:01:31.4949015", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-06T00:00:00", startTimeUtc = "2026-10-06T11:37:48.0185472", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-06T11:37:48.0185472", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-06T00:00:00", startTimeUtc = "2026-10-06T03:21:10.9150125", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-06T03:21:10.9150125", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-06T00:00:00", startTimeUtc = "2026-10-06T02:50:29.5547188", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-06T02:50:29.5547188", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-05T00:00:00", startTimeUtc = "2026-10-05T14:10:59.8916334", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-05T14:10:59.8916334", durationSeconds = 195, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-05T00:00:00", startTimeUtc = "2026-10-05T12:18:33.1689018", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-05T12:18:33.1689018", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7460, localDate = "2026-10-05T00:00:00", startTimeUtc = "2026-10-05T11:54:12.1093305", chapters = {
            { chapterId = 11285, startTimeUtc = "2026-10-05T11:54:12.1093305", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7460, localDate = "2026-10-05T00:00:00", startTimeUtc = "2026-10-05T11:34:55.3786363", chapters = {
            { chapterId = 11285, startTimeUtc = "2026-10-05T11:34:55.3786363", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7460, localDate = "2026-10-05T00:00:00", startTimeUtc = "2026-10-05T09:15:25.8448735", chapters = {
            { chapterId = 11285, startTimeUtc = "2026-10-05T09:15:25.8448735", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7460, localDate = "2026-10-04T00:00:00", startTimeUtc = "2026-10-04T09:36:48.7199331", chapters = {
            { chapterId = 11285, startTimeUtc = "2026-10-04T09:36:48.7199331", durationSeconds = 226, pagesRead = 0 } } },
    { seriesId = 7460, localDate = "2026-10-04T00:00:00", startTimeUtc = "2026-10-04T06:13:00.6097898", chapters = {
            { chapterId = 11285, startTimeUtc = "2026-10-04T06:13:00.6097898", durationSeconds = 412, pagesRead = 1 } } },
    { seriesId = 9249, localDate = "2026-10-03T00:00:00", startTimeUtc = "2026-10-03T14:24:26.495891", chapters = {
            { chapterId = 13493, startTimeUtc = "2026-10-03T14:24:26.495891", durationSeconds = 337, pagesRead = 0 } } },
    { seriesId = 7460, localDate = "2026-10-03T00:00:00", startTimeUtc = "2026-10-03T13:00:16.6885142", chapters = {
            { chapterId = 11285, startTimeUtc = "2026-10-03T13:00:16.6885142", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 10588, localDate = "2026-10-03T00:00:00", startTimeUtc = "2026-10-03T12:25:37.0931958", chapters = {
            { chapterId = 16914, startTimeUtc = "2026-10-03T12:25:37.0931958", durationSeconds = 358, pagesRead = 24 } } },
    { seriesId = 7460, localDate = "2026-10-03T00:00:00", startTimeUtc = "2026-10-03T12:09:12.6479717", chapters = {
            { chapterId = 11285, startTimeUtc = "2026-10-03T12:09:12.6479717", durationSeconds = 409, pagesRead = 1 } } },
    { seriesId = 7540, localDate = "2026-10-03T00:00:00", startTimeUtc = "2026-10-03T02:10:46.4251132", chapters = {
            { chapterId = 13394, startTimeUtc = "2026-10-03T02:10:46.4251132", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7540, localDate = "2026-10-02T00:00:00", startTimeUtc = "2026-10-02T04:04:43.6820861", chapters = {
            { chapterId = 13394, startTimeUtc = "2026-10-02T04:04:43.6820861", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7460, localDate = "2026-10-02T00:00:00", startTimeUtc = "2026-10-02T01:31:26.0795951", chapters = {
            { chapterId = 11285, startTimeUtc = "2026-10-02T01:31:26.0795951", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7460, localDate = "2026-10-02T00:00:00", startTimeUtc = "2026-10-02T01:19:47.6481957", chapters = {
            { chapterId = 11285, startTimeUtc = "2026-10-02T01:19:47.6481957", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7460, localDate = "2026-10-01T00:00:00", startTimeUtc = "2026-10-01T14:01:45.997983", chapters = {
            { chapterId = 11285, startTimeUtc = "2026-10-01T14:01:45.997983", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 10585, localDate = "2026-10-01T00:00:00", startTimeUtc = "2026-10-01T13:36:40.8506172", chapters = {
            { chapterId = 16862, startTimeUtc = "2026-10-01T13:36:40.8506172", durationSeconds = 113, pagesRead = 8 } } },
    { seriesId = 7460, localDate = "2026-10-01T00:00:00", startTimeUtc = "2026-10-01T13:35:51.0806955", chapters = {
            { chapterId = 11285, startTimeUtc = "2026-10-01T13:35:51.0806955", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7460, localDate = "2026-10-01T00:00:00", startTimeUtc = "2026-10-01T11:55:01.4289659", chapters = {
            { chapterId = 11285, startTimeUtc = "2026-10-01T11:55:01.4289659", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7460, localDate = "2026-10-01T00:00:00", startTimeUtc = "2026-10-01T11:41:02.5910426", chapters = {
            { chapterId = 11285, startTimeUtc = "2026-10-01T11:41:02.5910426", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7460, localDate = "2026-10-01T00:00:00", startTimeUtc = "2026-10-01T11:28:36.4902671", chapters = {
            { chapterId = 11285, startTimeUtc = "2026-10-01T11:28:36.4902671", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7460, localDate = "2026-10-01T00:00:00", startTimeUtc = "2026-10-01T11:10:02.1536935", chapters = {
            { chapterId = 11285, startTimeUtc = "2026-10-01T11:10:02.1536935", durationSeconds = 289, pagesRead = 0 } } },
    { seriesId = 10585, localDate = "2026-10-01T00:00:00", startTimeUtc = "2026-10-01T11:04:28.7600787", chapters = {
            { chapterId = 16862, startTimeUtc = "2026-10-01T11:04:28.7600787", durationSeconds = 241, pagesRead = 15 } } },
    { seriesId = 7540, localDate = "2026-10-01T00:00:00", startTimeUtc = "2026-10-01T10:32:28.7130273", chapters = {
            { chapterId = 13394, startTimeUtc = "2026-10-01T10:32:28.7130273", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 8661, localDate = "2026-09-30T00:00:00", startTimeUtc = "2026-09-30T13:03:27.0677663", chapters = {
            { chapterId = 12763, startTimeUtc = "2026-09-30T13:03:27.0677663", durationSeconds = 1530, pagesRead = -3 } } },
    { seriesId = 7540, localDate = "2026-09-30T00:00:00", startTimeUtc = "2026-09-30T13:02:32.9357375", chapters = {
            { chapterId = 13394, startTimeUtc = "2026-09-30T13:02:32.9357375", durationSeconds = 22, pagesRead = 0 } } },
    { seriesId = 7540, localDate = "2026-09-30T00:00:00", startTimeUtc = "2026-09-30T12:28:33.282795", chapters = {
            { chapterId = 13394, startTimeUtc = "2026-09-30T12:28:33.282795", durationSeconds = 189, pagesRead = 0 } } },
    { seriesId = 8661, localDate = "2026-09-30T00:00:00", startTimeUtc = "2026-09-30T11:37:13.1197026", chapters = {
            { chapterId = 12763, startTimeUtc = "2026-09-30T11:37:13.1197026", durationSeconds = 25, pagesRead = 0 } } },
    { seriesId = 7540, localDate = "2026-09-30T00:00:00", startTimeUtc = "2026-09-30T11:33:44.6966312", chapters = {
            { chapterId = 13394, startTimeUtc = "2026-09-30T11:33:44.6966312", durationSeconds = 130, pagesRead = 0 } } },
    { seriesId = 7540, localDate = "2026-09-30T00:00:00", startTimeUtc = "2026-09-30T09:14:25.3316858", chapters = {
            { chapterId = 13394, startTimeUtc = "2026-09-30T09:14:25.3316858", durationSeconds = 37, pagesRead = -4 } } },
    { seriesId = 7540, localDate = "2026-09-30T00:00:00", startTimeUtc = "2026-09-30T08:52:37.2436808", chapters = {
            { chapterId = 13394, startTimeUtc = "2026-09-30T08:52:37.2436808", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7540, localDate = "2026-09-30T00:00:00", startTimeUtc = "2026-09-30T07:54:07.7610298", chapters = {
            { chapterId = 13394, startTimeUtc = "2026-09-30T07:54:07.7610298", durationSeconds = 5, pagesRead = 0 } } },
    { seriesId = 7805, localDate = "2026-09-30T00:00:00", startTimeUtc = "2026-09-30T03:56:53.2380567", chapters = {
            { chapterId = 11791, startTimeUtc = "2026-09-30T03:56:53.2380567", durationSeconds = 6, pagesRead = 0 } } },
    { seriesId = 7540, localDate = "2026-09-30T00:00:00", startTimeUtc = "2026-09-30T03:42:57.6124947", chapters = {
            { chapterId = 13394, startTimeUtc = "2026-09-30T03:42:57.6124947", durationSeconds = 1749, pagesRead = 4 } } },
    { seriesId = 7540, localDate = "2026-09-30T00:00:00", startTimeUtc = "2026-09-30T03:23:47.6591832", chapters = {
            { chapterId = 13394, startTimeUtc = "2026-09-30T03:23:47.6591832", durationSeconds = 548, pagesRead = 0 } } },
    { seriesId = 10684, localDate = "2026-09-30T00:00:00", startTimeUtc = "2026-09-30T03:12:37.6514083", chapters = {
            { chapterId = 18895, startTimeUtc = "2026-09-30T03:12:37.6514083", durationSeconds = 68, pagesRead = 15 } } },
    { seriesId = 10556, localDate = "2026-09-30T00:00:00", startTimeUtc = "2026-09-30T01:58:37.2644751", chapters = {
            { chapterId = 16398, startTimeUtc = "2026-09-30T01:58:37.2644751", durationSeconds = 5, pagesRead = 6 } } },
    { seriesId = 7805, localDate = "2026-09-30T00:00:00", startTimeUtc = "2026-09-30T00:43:20.1361231", chapters = {
            { chapterId = 11791, startTimeUtc = "2026-09-30T01:16:48.8842393", durationSeconds = 387, pagesRead = 0 },
            { chapterId = 11791, startTimeUtc = "2026-09-30T00:43:20.1361231", durationSeconds = 204, pagesRead = 1 } } },
    { seriesId = 8661, localDate = "2026-09-30T00:00:00", startTimeUtc = "2026-09-30T00:46:55.2653707", chapters = {
            { chapterId = 12763, startTimeUtc = "2026-09-30T00:46:55.2653707", durationSeconds = 1330, pagesRead = 3 } } },
    { seriesId = 7460, localDate = "2026-09-30T00:00:00", startTimeUtc = "2026-09-30T00:25:09.4803818", chapters = {
            { chapterId = 11285, startTimeUtc = "2026-09-30T00:37:14.7633119", durationSeconds = 43, pagesRead = 0 },
            { chapterId = 11285, startTimeUtc = "2026-09-30T00:25:09.4803818", durationSeconds = 32, pagesRead = 0 } } },
    { seriesId = 7540, localDate = "2026-09-30T00:00:00", startTimeUtc = "2026-09-30T00:30:04.5325361", chapters = {
            { chapterId = 13394, startTimeUtc = "2026-09-30T00:30:04.5325361", durationSeconds = 222, pagesRead = -1 } } },
    { seriesId = 9249, localDate = "2026-09-30T00:00:00", startTimeUtc = "2026-09-30T00:27:17.7123717", chapters = {
            { chapterId = 13493, startTimeUtc = "2026-09-30T00:27:17.7123717", durationSeconds = 108, pagesRead = 1 } } },
    { seriesId = 10584, localDate = "2026-09-29T00:00:00", startTimeUtc = "2026-09-29T15:27:07.2391439", chapters = {
            { chapterId = 16853, startTimeUtc = "2026-09-29T15:27:07.2391439", durationSeconds = 6, pagesRead = 6 } } },
    { seriesId = 7460, localDate = "2026-09-29T00:00:00", startTimeUtc = "2026-09-29T15:23:24.6913136", chapters = {
            { chapterId = 11285, startTimeUtc = "2026-09-29T15:23:24.6913136", durationSeconds = 51, pagesRead = 1 } } },
    { seriesId = 10584, localDate = "2026-09-29T00:00:00", startTimeUtc = "2026-09-29T15:11:40.8997791", chapters = {
            { chapterId = 16853, startTimeUtc = "2026-09-29T15:11:40.8997791", durationSeconds = 24, pagesRead = 14 } } },
    { seriesId = 8661, localDate = "2026-09-29T00:00:00", startTimeUtc = "2026-09-29T15:10:15.9077958", chapters = {
            { chapterId = 12763, startTimeUtc = "2026-09-29T15:10:15.9077958", durationSeconds = 23, pagesRead = 6 } } },
    { seriesId = 7540, localDate = "2026-09-29T00:00:00", startTimeUtc = "2026-09-29T15:02:32.6735695", chapters = {
            { chapterId = 13394, startTimeUtc = "2026-09-29T15:02:32.6735695", durationSeconds = 452, pagesRead = 7 } } },
    { seriesId = 7460, localDate = "2026-09-29T00:00:00", startTimeUtc = "2026-09-29T14:58:04.6106466", chapters = {
            { chapterId = 11285, startTimeUtc = "2026-09-29T14:58:04.6106466", durationSeconds = 82, pagesRead = 0 } } },
    { seriesId = 9249, localDate = "2026-09-29T00:00:00", startTimeUtc = "2026-09-29T14:38:04.1555096", chapters = {
            { chapterId = 13493, startTimeUtc = "2026-09-29T14:38:04.1555096", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 9249, localDate = "2026-09-29T00:00:00", startTimeUtc = "2026-09-29T14:12:48.9320003", chapters = {
            { chapterId = 13493, startTimeUtc = "2026-09-29T14:12:48.9320003", durationSeconds = 86, pagesRead = 3 } } },
    { seriesId = 7460, localDate = "2026-09-29T00:00:00", startTimeUtc = "2026-09-29T14:07:43.3739949", chapters = {
            { chapterId = 11285, startTimeUtc = "2026-09-29T14:07:43.3739949", durationSeconds = 439, pagesRead = 20 } } },
    { seriesId = 10560, localDate = "2026-09-29T00:00:00", startTimeUtc = "2026-09-29T13:55:37.9561391", chapters = {
            { chapterId = 16493, startTimeUtc = "2026-09-29T13:55:37.9561391", durationSeconds = 0, pagesRead = 1 } } },
    { seriesId = 9249, localDate = "2026-09-29T00:00:00", startTimeUtc = "2026-09-29T12:39:52.7733874", chapters = {
            { chapterId = 13493, startTimeUtc = "2026-09-29T12:39:52.7733874", durationSeconds = 31, pagesRead = 3 } } },
    { seriesId = 10559, localDate = "2026-09-29T00:00:00", startTimeUtc = "2026-09-29T12:33:10.2857117", chapters = {
            { chapterId = 16479, startTimeUtc = "2026-09-29T12:33:10.2857117", durationSeconds = 7, pagesRead = 15 } } },
    { seriesId = 10560, localDate = "2026-09-29T00:00:00", startTimeUtc = "2026-09-29T11:51:35.4694759", chapters = {
            { chapterId = 16493, startTimeUtc = "2026-09-29T12:22:43.7993875", durationSeconds = 936, pagesRead = 2 },
            { chapterId = 16493, startTimeUtc = "2026-09-29T11:51:35.4694759", durationSeconds = 1223, pagesRead = 12 } } },
    { seriesId = 7460, localDate = "2026-09-29T00:00:00", startTimeUtc = "2026-09-29T11:58:50.1222492", chapters = {
            { chapterId = 11285, startTimeUtc = "2026-09-29T12:21:19.3748615", durationSeconds = 909, pagesRead = -2 },
            { chapterId = 11285, startTimeUtc = "2026-09-29T11:58:50.1222492", durationSeconds = 20, pagesRead = 0 } } },
    { seriesId = 10563, localDate = "2026-09-29T00:00:00", startTimeUtc = "2026-09-29T12:17:34.2571271", chapters = {
            { chapterId = 16505, startTimeUtc = "2026-09-29T12:17:34.2571271", durationSeconds = 36, pagesRead = 17 } } },
    { seriesId = 10562, localDate = "2026-09-29T00:00:00", startTimeUtc = "2026-09-29T12:07:43.0627869", chapters = {
            { chapterId = 16502, startTimeUtc = "2026-09-29T12:07:43.0627869", durationSeconds = 70, pagesRead = 17 } } },
    { seriesId = 7910, localDate = "2026-09-29T00:00:00", startTimeUtc = "2026-09-29T11:50:25.270629", chapters = {
            { chapterId = 11904, startTimeUtc = "2026-09-29T11:50:25.270629", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7910, localDate = "2026-09-29T00:00:00", startTimeUtc = "2026-09-29T11:25:02.6769601", chapters = {
            { chapterId = 11896, startTimeUtc = "2026-09-29T11:25:16.5490822", durationSeconds = 442, pagesRead = 6 },
            { chapterId = 11898, startTimeUtc = "2026-09-29T11:25:02.6769601", durationSeconds = 328, pagesRead = 1 } } },
    { seriesId = 7460, localDate = "2026-09-29T00:00:00", startTimeUtc = "2026-09-29T11:24:52.8021347", chapters = {
            { chapterId = 11285, startTimeUtc = "2026-09-29T11:24:52.8021347", durationSeconds = 525, pagesRead = 15 } } },
    { seriesId = 10639, localDate = "2026-09-29T00:00:00", startTimeUtc = "2026-09-29T11:08:39.2618986", chapters = {
            { chapterId = 18031, startTimeUtc = "2026-09-29T11:08:39.2618986", durationSeconds = 0, pagesRead = 1 } } },
    { seriesId = 10556, localDate = "2026-09-29T00:00:00", startTimeUtc = "2026-09-29T10:56:40.6001656", chapters = {
            { chapterId = 16398, startTimeUtc = "2026-09-29T10:56:40.6001656", durationSeconds = 11, pagesRead = 9 } } },
    { seriesId = 7460, localDate = "2026-09-29T00:00:00", startTimeUtc = "2026-09-29T10:45:47.6455857", chapters = {
            { chapterId = 11285, startTimeUtc = "2026-09-29T10:45:47.6455857", durationSeconds = 4, pagesRead = 4 } } },
    { seriesId = 7462, localDate = "2026-09-29T00:00:00", startTimeUtc = "2026-09-29T10:45:05.5896105", chapters = {
            { chapterId = 11290, startTimeUtc = "2026-09-29T10:45:05.5896105", durationSeconds = 3, pagesRead = 1 } } },
    { seriesId = 7540, localDate = "2026-09-29T00:00:00", startTimeUtc = "2026-09-29T10:35:52.0518521", chapters = {
            { chapterId = 13394, startTimeUtc = "2026-09-29T10:35:52.0518521", durationSeconds = 39, pagesRead = 6 } } },
    { seriesId = 7805, localDate = "2026-09-29T00:00:00", startTimeUtc = "2026-09-29T10:34:39.8658599", chapters = {
            { chapterId = 11791, startTimeUtc = "2026-09-29T10:34:39.8658599", durationSeconds = 12, pagesRead = 3 } } },
    { seriesId = 7453, localDate = "2026-09-29T00:00:00", startTimeUtc = "2026-09-29T10:25:25.4088288", chapters = {
            { chapterId = 11271, startTimeUtc = "2026-09-29T10:25:25.4088288", durationSeconds = 86, pagesRead = 2 } } },
    { seriesId = 10004, localDate = "2026-09-29T00:00:00", startTimeUtc = "2026-09-29T10:22:33.7903381", chapters = {
            { chapterId = 14594, startTimeUtc = "2026-09-29T10:22:33.7903381", durationSeconds = 167, pagesRead = 4 } } },
    { seriesId = 7453, localDate = "2026-09-29T00:00:00", startTimeUtc = "2026-09-29T10:01:44.7835505", chapters = {
            { chapterId = 11271, startTimeUtc = "2026-09-29T10:01:44.7835505", durationSeconds = 230, pagesRead = 0 } } },
    { seriesId = 10001, localDate = "2026-09-29T00:00:00", startTimeUtc = "2026-09-29T09:57:30.1875022", chapters = {
            { chapterId = 14591, startTimeUtc = "2026-09-29T09:57:30.1875022", durationSeconds = 14, pagesRead = 0 } } },
    { seriesId = 7460, localDate = "2026-09-29T00:00:00", startTimeUtc = "2026-09-29T09:39:33.8232177", chapters = {
            { chapterId = 11285, startTimeUtc = "2026-09-29T09:39:33.8232177", durationSeconds = 332, pagesRead = 19 } } },
    { seriesId = 7476, localDate = "2026-09-29T00:00:00", startTimeUtc = "2026-09-29T09:30:15.0902649", chapters = {
            { chapterId = 11317, startTimeUtc = "2026-09-29T09:30:15.0902649", durationSeconds = 27, pagesRead = 0 } } },
    { seriesId = 7476, localDate = "2026-09-29T00:00:00", startTimeUtc = "2026-09-29T09:02:28.8339509", chapters = {
            { chapterId = 11317, startTimeUtc = "2026-09-29T09:02:28.8339509", durationSeconds = 267, pagesRead = 0 } } },
    { seriesId = 10004, localDate = "2026-09-29T00:00:00", startTimeUtc = "2026-09-29T08:51:39.2655404", chapters = {
            { chapterId = 14594, startTimeUtc = "2026-09-29T08:51:39.2655404", durationSeconds = 39, pagesRead = 0 } } },
    { seriesId = 10004, localDate = "2026-09-29T00:00:00", startTimeUtc = "2026-09-29T08:33:15.8755207", chapters = {
            { chapterId = 14594, startTimeUtc = "2026-09-29T08:33:15.8755207", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 10004, localDate = "2026-09-29T00:00:00", startTimeUtc = "2026-09-29T08:14:10.4993494", chapters = {
            { chapterId = 14594, startTimeUtc = "2026-09-29T08:14:10.4993494", durationSeconds = 106, pagesRead = 0 } } },
    { seriesId = 7476, localDate = "2026-09-29T00:00:00", startTimeUtc = "2026-09-29T07:47:38.8544242", chapters = {
            { chapterId = 11317, startTimeUtc = "2026-09-29T08:02:48.272453", durationSeconds = 461, pagesRead = -1 },
            { chapterId = 11317, startTimeUtc = "2026-09-29T07:47:38.8544242", durationSeconds = 39, pagesRead = 7 } } },
    { seriesId = 7452, localDate = "2026-09-29T00:00:00", startTimeUtc = "2026-09-29T07:51:52.786463", chapters = {
            { chapterId = 11269, startTimeUtc = "2026-09-29T07:51:52.786463", durationSeconds = 365, pagesRead = 115 } } },
    { seriesId = 10042, localDate = "2026-09-29T00:00:00", startTimeUtc = "2026-09-29T07:39:42.880422", chapters = {
            { chapterId = 14638, startTimeUtc = "2026-09-29T07:39:42.880422", durationSeconds = 50, pagesRead = 0 } } },
    { seriesId = 7540, localDate = "2026-09-28T00:00:00", startTimeUtc = "2026-09-28T09:16:47.6382365", chapters = {
            { chapterId = 13394, startTimeUtc = "2026-09-28T09:16:47.6382365", durationSeconds = 59, pagesRead = 0 } } },
    { seriesId = 9158, localDate = "2026-09-28T00:00:00", startTimeUtc = "2026-09-27T17:16:38.7193514", chapters = {
            { chapterId = 13395, startTimeUtc = "2026-09-27T17:16:38.7193514", durationSeconds = 29, pagesRead = 1 } } },
    { seriesId = 10683, localDate = "2026-09-28T00:00:00", startTimeUtc = "2026-09-27T17:13:53.8061535", chapters = {
            { chapterId = 18893, startTimeUtc = "2026-09-27T17:13:53.8061535", durationSeconds = 16, pagesRead = -1 } } },
    { seriesId = 7540, localDate = "2026-09-27T00:00:00", startTimeUtc = "2026-09-27T15:13:47.085122", chapters = {
            { chapterId = 13394, startTimeUtc = "2026-09-27T15:13:47.085122", durationSeconds = 746, pagesRead = 0 } } },
    { seriesId = 7540, localDate = "2026-09-27T00:00:00", startTimeUtc = "2026-09-27T13:34:49.3907937", chapters = {
            { chapterId = 13394, startTimeUtc = "2026-09-27T13:34:49.3907937", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7540, localDate = "2026-09-27T00:00:00", startTimeUtc = "2026-09-27T13:03:53.8173515", chapters = {
            { chapterId = 13394, startTimeUtc = "2026-09-27T13:03:53.8173515", durationSeconds = 9, pagesRead = 0 } } },
    { seriesId = 7540, localDate = "2026-09-27T00:00:00", startTimeUtc = "2026-09-27T09:21:25.6490847", chapters = {
            { chapterId = 13394, startTimeUtc = "2026-09-27T09:21:25.6490847", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7540, localDate = "2026-09-27T00:00:00", startTimeUtc = "2026-09-27T09:03:41.6524393", chapters = {
            { chapterId = 13394, startTimeUtc = "2026-09-27T09:03:41.6524393", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7540, localDate = "2026-09-27T00:00:00", startTimeUtc = "2026-09-27T01:38:10.6211012", chapters = {
            { chapterId = 13394, startTimeUtc = "2026-09-27T01:38:10.6211012", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7540, localDate = "2026-09-26T00:00:00", startTimeUtc = "2026-09-26T15:13:21.9970834", chapters = {
            { chapterId = 13394, startTimeUtc = "2026-09-26T15:13:21.9970834", durationSeconds = 14, pagesRead = 4 } } },
    { seriesId = 8110, localDate = "2026-09-26T00:00:00", startTimeUtc = "2026-09-26T14:58:04.4305334", chapters = {
            { chapterId = 12126, startTimeUtc = "2026-09-26T14:58:04.4305334", durationSeconds = 181, pagesRead = 1 } } },
    { seriesId = 8110, localDate = "2026-09-26T00:00:00", startTimeUtc = "2026-09-26T14:37:55.4114027", chapters = {
            { chapterId = 12126, startTimeUtc = "2026-09-26T14:37:55.4114027", durationSeconds = 55, pagesRead = 1 } } },
    { seriesId = 7460, localDate = "2026-09-26T00:00:00", startTimeUtc = "2026-09-26T14:33:39.6298963", chapters = {
            { chapterId = 11285, startTimeUtc = "2026-09-26T14:33:39.6298963", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7460, localDate = "2026-09-26T00:00:00", startTimeUtc = "2026-09-26T14:19:48.5269015", chapters = {
            { chapterId = 11285, startTimeUtc = "2026-09-26T14:19:48.5269015", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 10676, localDate = "2026-09-26T00:00:00", startTimeUtc = "2026-09-26T13:34:15.9269344", chapters = {
            { chapterId = 18818, startTimeUtc = "2026-09-26T13:34:15.9269344", durationSeconds = 1021, pagesRead = 54 } } },
    { seriesId = 10676, localDate = "2026-09-26T00:00:00", startTimeUtc = "2026-09-26T12:08:23.540117", chapters = {
            { chapterId = 18818, startTimeUtc = "2026-09-26T12:08:23.540117", durationSeconds = 107, pagesRead = 11 } } },
    { seriesId = 7460, localDate = "2026-09-26T00:00:00", startTimeUtc = "2026-09-26T12:07:39.7719041", chapters = {
            { chapterId = 11285, startTimeUtc = "2026-09-26T12:07:39.7719041", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7460, localDate = "2026-09-26T00:00:00", startTimeUtc = "2026-09-26T01:55:50.078051", chapters = {
            { chapterId = 11285, startTimeUtc = "2026-09-26T01:55:50.078051", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7460, localDate = "2026-09-26T00:00:00", startTimeUtc = "2026-09-26T01:32:58.4149147", chapters = {
            { chapterId = 11285, startTimeUtc = "2026-09-26T01:32:58.4149147", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7460, localDate = "2026-09-26T00:00:00", startTimeUtc = "2026-09-26T01:13:02.4223873", chapters = {
            { chapterId = 11285, startTimeUtc = "2026-09-26T01:13:02.4223873", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 9110, localDate = "2026-09-25T00:00:00", startTimeUtc = "2026-09-25T14:23:56.0117314", chapters = {
            { chapterId = 13318, startTimeUtc = "2026-09-25T14:23:56.0117314", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 9110, localDate = "2026-09-25T00:00:00", startTimeUtc = "2026-09-25T13:59:56.4928672", chapters = {
            { chapterId = 13318, startTimeUtc = "2026-09-25T13:59:56.4928672", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 9110, localDate = "2026-09-25T00:00:00", startTimeUtc = "2026-09-25T07:58:26.2227579", chapters = {
            { chapterId = 13318, startTimeUtc = "2026-09-25T07:58:26.2227579", durationSeconds = 3, pagesRead = 0 } } },
    { seriesId = 8110, localDate = "2026-09-25T00:00:00", startTimeUtc = "2026-09-25T07:08:30.8014023", chapters = {
            { chapterId = 12126, startTimeUtc = "2026-09-25T07:08:30.8014023", durationSeconds = 7, pagesRead = 3 } } },
    { seriesId = 7460, localDate = "2026-09-25T00:00:00", startTimeUtc = "2026-09-25T01:28:12.7465578", chapters = {
            { chapterId = 11285, startTimeUtc = "2026-09-25T01:28:12.7465578", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 10663, localDate = "2026-09-24T00:00:00", startTimeUtc = "2026-09-24T14:34:51.9798262", chapters = {
            { chapterId = 18514, startTimeUtc = "2026-09-24T14:34:51.9798262", durationSeconds = 59, pagesRead = 10 } } },
    { seriesId = 10682, localDate = "2026-09-24T00:00:00", startTimeUtc = "2026-09-24T14:00:55.5695168", chapters = {
            { chapterId = 18889, startTimeUtc = "2026-09-24T14:00:55.5695168", durationSeconds = 65, pagesRead = 8 } } },
    { seriesId = 10634, localDate = "2026-09-24T00:00:00", startTimeUtc = "2026-09-24T13:41:48.3170857", chapters = {
            { chapterId = 17855, startTimeUtc = "2026-09-24T13:41:48.3170857", durationSeconds = 328, pagesRead = 65 } } },
    { seriesId = 10663, localDate = "2026-09-24T00:00:00", startTimeUtc = "2026-09-24T12:55:37.0956115", chapters = {
            { chapterId = 18514, startTimeUtc = "2026-09-24T12:55:37.0956115", durationSeconds = 44, pagesRead = 8 } } },
    { seriesId = 10634, localDate = "2026-09-24T00:00:00", startTimeUtc = "2026-09-24T12:54:21.9067307", chapters = {
            { chapterId = 17855, startTimeUtc = "2026-09-24T12:54:21.9067307", durationSeconds = 8, pagesRead = 4 } } },
    { seriesId = 10634, localDate = "2026-09-24T00:00:00", startTimeUtc = "2026-09-24T11:36:17.6978208", chapters = {
            { chapterId = 17855, startTimeUtc = "2026-09-24T11:36:17.6978208", durationSeconds = 56, pagesRead = 14 } } },
    { seriesId = 10682, localDate = "2026-09-24T00:00:00", startTimeUtc = "2026-09-24T09:54:25.899822", chapters = {
            { chapterId = 18889, startTimeUtc = "2026-09-24T09:54:25.899822", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 10674, localDate = "2026-09-24T00:00:00", startTimeUtc = "2026-09-24T09:27:10.4132213", chapters = {
            { chapterId = 18789, startTimeUtc = "2026-09-24T09:27:10.4132213", durationSeconds = 8, pagesRead = 3 } } },
    { seriesId = 9249, localDate = "2026-09-24T00:00:00", startTimeUtc = "2026-09-24T07:47:32.97548", chapters = {
            { chapterId = 13493, startTimeUtc = "2026-09-24T07:47:32.97548", durationSeconds = 461, pagesRead = 0 } } },
    { seriesId = 9249, localDate = "2026-09-24T00:00:00", startTimeUtc = "2026-09-24T07:26:01.1542479", chapters = {
            { chapterId = 13493, startTimeUtc = "2026-09-24T07:26:01.1542479", durationSeconds = 146, pagesRead = 0 } } },
    { seriesId = 9095, localDate = "2026-09-24T00:00:00", startTimeUtc = "2026-09-24T06:46:54.4314754", chapters = {
            { chapterId = 13282, startTimeUtc = "2026-09-24T06:46:54.4314754", durationSeconds = 0, pagesRead = 1 } } },
    { seriesId = 9649, localDate = "2026-09-24T00:00:00", startTimeUtc = "2026-09-23T16:09:03.1098014", chapters = {
            { chapterId = 14126, startTimeUtc = "2026-09-23T16:09:03.1098014", durationSeconds = 4, pagesRead = 2 } } },
    { seriesId = 7461, localDate = "2026-09-24T00:00:00", startTimeUtc = "2026-09-23T16:05:48.0362145", chapters = {
            { chapterId = 11312, startTimeUtc = "2026-09-23T16:05:48.0362145", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7460, localDate = "2026-09-23T00:00:00", startTimeUtc = "2026-09-23T13:47:22.8458997", chapters = {
            { chapterId = 11285, startTimeUtc = "2026-09-23T13:47:22.8458997", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 8137, localDate = "2026-09-23T00:00:00", startTimeUtc = "2026-09-23T05:52:39.9019755", chapters = {
            { chapterId = 12159, startTimeUtc = "2026-09-23T05:52:39.9019755", durationSeconds = 79, pagesRead = 18 } } },
    { seriesId = 9249, localDate = "2026-09-23T00:00:00", startTimeUtc = "2026-09-23T03:51:46.3681335", chapters = {
            { chapterId = 13493, startTimeUtc = "2026-09-23T03:51:46.3681335", durationSeconds = 327, pagesRead = 0 } } },
    { seriesId = 9262, localDate = "2026-09-22T00:00:00", startTimeUtc = "2026-09-22T13:38:38.3358566", chapters = {
            { chapterId = 13508, startTimeUtc = "2026-09-22T13:38:38.3358566", durationSeconds = 52, pagesRead = 4 } } },
    { seriesId = 9249, localDate = "2026-09-22T00:00:00", startTimeUtc = "2026-09-22T13:22:52.4340931", chapters = {
            { chapterId = 13493, startTimeUtc = "2026-09-22T13:22:52.4340931", durationSeconds = 5, pagesRead = 0 } } },
    { seriesId = 7460, localDate = "2026-09-22T00:00:00", startTimeUtc = "2026-09-22T10:28:46.3070635", chapters = {
            { chapterId = 11285, startTimeUtc = "2026-09-22T10:28:46.3070635", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7460, localDate = "2026-09-22T00:00:00", startTimeUtc = "2026-09-22T09:53:02.9688203", chapters = {
            { chapterId = 11285, startTimeUtc = "2026-09-22T09:53:02.9688203", durationSeconds = 515, pagesRead = 1 } } },
    { seriesId = 9257, localDate = "2026-09-22T00:00:00", startTimeUtc = "2026-09-22T09:45:09.829169", chapters = {
            { chapterId = 13503, startTimeUtc = "2026-09-22T09:45:09.829169", durationSeconds = 5, pagesRead = 11 } } },
    { seriesId = 9249, localDate = "2026-09-22T00:00:00", startTimeUtc = "2026-09-22T08:59:44.2021935", chapters = {
            { chapterId = 13493, startTimeUtc = "2026-09-22T08:59:44.2021935", durationSeconds = 85, pagesRead = 0 } } },
    { seriesId = 7460, localDate = "2026-09-22T00:00:00", startTimeUtc = "2026-09-22T08:57:31.3039746", chapters = {
            { chapterId = 11285, startTimeUtc = "2026-09-22T08:57:31.3039746", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7460, localDate = "2026-09-22T00:00:00", startTimeUtc = "2026-09-22T08:34:21.7362395", chapters = {
            { chapterId = 11285, startTimeUtc = "2026-09-22T08:34:21.7362395", durationSeconds = 697, pagesRead = 0 } } },
    { seriesId = 9249, localDate = "2026-09-22T00:00:00", startTimeUtc = "2026-09-22T08:00:48.3941463", chapters = {
            { chapterId = 13493, startTimeUtc = "2026-09-22T08:00:48.3941463", durationSeconds = 149, pagesRead = 2 } } },
    { seriesId = 9180, localDate = "2026-09-22T00:00:00", startTimeUtc = "2026-09-22T03:13:37.560087", chapters = {
            { chapterId = 13420, startTimeUtc = "2026-09-22T03:13:37.560087", durationSeconds = 11, pagesRead = 7 } } },
    { seriesId = 7460, localDate = "2026-09-22T00:00:00", startTimeUtc = "2026-09-22T02:24:02.4880326", chapters = {
            { chapterId = 11285, startTimeUtc = "2026-09-22T02:24:02.4880326", durationSeconds = 163, pagesRead = 0 } } },
    { seriesId = 7460, localDate = "2026-09-21T00:00:00", startTimeUtc = "2026-09-21T13:24:04.9528675", chapters = {
            { chapterId = 11285, startTimeUtc = "2026-09-21T13:24:04.9528675", durationSeconds = 307, pagesRead = 1 } } },
    { seriesId = 7805, localDate = "2026-09-21T00:00:00", startTimeUtc = "2026-09-21T13:07:31.7048466", chapters = {
            { chapterId = 11791, startTimeUtc = "2026-09-21T13:07:31.7048466", durationSeconds = 8, pagesRead = 0 } } },
    { seriesId = 8661, localDate = "2026-09-21T00:00:00", startTimeUtc = "2026-09-21T13:04:31.936106", chapters = {
            { chapterId = 12763, startTimeUtc = "2026-09-21T13:04:31.936106", durationSeconds = 84, pagesRead = 0 } } },
    { seriesId = 8661, localDate = "2026-09-21T00:00:00", startTimeUtc = "2026-09-21T10:07:50.9423535", chapters = {
            { chapterId = 12763, startTimeUtc = "2026-09-21T10:07:50.9423535", durationSeconds = 563, pagesRead = 5 } } },
    { seriesId = 7805, localDate = "2026-09-21T00:00:00", startTimeUtc = "2026-09-21T09:56:54.7828239", chapters = {
            { chapterId = 11791, startTimeUtc = "2026-09-21T09:56:54.7828239", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 9110, localDate = "2026-09-21T00:00:00", startTimeUtc = "2026-09-21T04:49:43.5918775", chapters = {
            { chapterId = 13318, startTimeUtc = "2026-09-21T04:49:43.5918775", durationSeconds = 207, pagesRead = 4 } } },
    { seriesId = 7603, localDate = "2026-09-21T00:00:00", startTimeUtc = "2026-09-21T04:49:04.8491169", chapters = {
            { chapterId = 11484, startTimeUtc = "2026-09-21T04:49:04.8491169", durationSeconds = 6, pagesRead = 4 } } },
    { seriesId = 7603, localDate = "2026-09-21T00:00:00", startTimeUtc = "2026-09-21T03:38:08.3558687", chapters = {
            { chapterId = 11484, startTimeUtc = "2026-09-21T03:38:08.3558687", durationSeconds = 8, pagesRead = 4 } } },
    { seriesId = 8247, localDate = "2026-09-20T00:00:00", startTimeUtc = "2026-09-20T14:14:20.693305", chapters = {
            { chapterId = 12300, startTimeUtc = "2026-09-20T14:14:20.693305", durationSeconds = 86, pagesRead = 6 } } },
    { seriesId = 8281, localDate = "2026-09-20T00:00:00", startTimeUtc = "2026-09-20T14:11:24.8897015", chapters = {
            { chapterId = 12334, startTimeUtc = "2026-09-20T14:11:24.8897015", durationSeconds = 25, pagesRead = 1 } } },
    { seriesId = 7476, localDate = "2026-09-20T00:00:00", startTimeUtc = "2026-09-20T13:17:19.1246015", chapters = {
            { chapterId = 11317, startTimeUtc = "2026-09-20T13:17:19.1246015", durationSeconds = 34, pagesRead = 7 } } },
    { seriesId = 7805, localDate = "2026-09-20T00:00:00", startTimeUtc = "2026-09-20T13:07:24.1160188", chapters = {
            { chapterId = 11791, startTimeUtc = "2026-09-20T13:07:24.1160188", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 8310, localDate = "2026-09-20T00:00:00", startTimeUtc = "2026-09-20T09:52:07.5117003", chapters = {
            { chapterId = 12363, startTimeUtc = "2026-09-20T09:52:07.5117003", durationSeconds = 671, pagesRead = 3 } } },
    { seriesId = 8310, localDate = "2026-09-20T00:00:00", startTimeUtc = "2026-09-20T09:32:51.5623005", chapters = {
            { chapterId = 12363, startTimeUtc = "2026-09-20T09:32:51.5623005", durationSeconds = 364, pagesRead = 1 } } },
    { seriesId = 8106, localDate = "2026-09-20T00:00:00", startTimeUtc = "2026-09-20T08:11:17.3798059", chapters = {
            { chapterId = 12122, startTimeUtc = "2026-09-20T08:11:17.3798059", durationSeconds = 35, pagesRead = 5 } } },
    { seriesId = 7510, localDate = "2026-09-20T00:00:00", startTimeUtc = "2026-09-20T07:50:30.9737641", chapters = {
            { chapterId = 11360, startTimeUtc = "2026-09-20T07:50:30.9737641", durationSeconds = 19, pagesRead = 0 } } },
    { seriesId = 7805, localDate = "2026-09-20T00:00:00", startTimeUtc = "2026-09-20T07:47:25.7922257", chapters = {
            { chapterId = 11791, startTimeUtc = "2026-09-20T07:47:25.7922257", durationSeconds = 3, pagesRead = 0 } } },
    { seriesId = 7461, localDate = "2026-09-20T00:00:00", startTimeUtc = "2026-09-20T07:25:56.7820012", chapters = {
            { chapterId = 11312, startTimeUtc = "2026-09-20T07:25:56.7820012", durationSeconds = 427, pagesRead = 2 } } },
    { seriesId = 7461, localDate = "2026-09-20T00:00:00", startTimeUtc = "2026-09-20T07:01:03.0337544", chapters = {
            { chapterId = 11312, startTimeUtc = "2026-09-20T07:01:03.0337544", durationSeconds = 311, pagesRead = 0 } } },
    { seriesId = 7461, localDate = "2026-09-20T00:00:00", startTimeUtc = "2026-09-20T04:37:11.2011378", chapters = {
            { chapterId = 11312, startTimeUtc = "2026-09-20T04:37:11.2011378", durationSeconds = 407, pagesRead = 0 } } },
    { seriesId = 7460, localDate = "2026-09-20T00:00:00", startTimeUtc = "2026-09-20T04:29:53.9882097", chapters = {
            { chapterId = 11285, startTimeUtc = "2026-09-20T04:29:53.9882097", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7461, localDate = "2026-09-20T00:00:00", startTimeUtc = "2026-09-20T03:23:39.822214", chapters = {
            { chapterId = 11312, startTimeUtc = "2026-09-20T03:23:39.822214", durationSeconds = 431, pagesRead = 0 } } },
    { seriesId = 7461, localDate = "2026-09-19T00:00:00", startTimeUtc = "2026-09-19T14:37:14.3112506", chapters = {
            { chapterId = 11312, startTimeUtc = "2026-09-19T14:37:14.3112506", durationSeconds = 460, pagesRead = 0 } } },
    { seriesId = 7461, localDate = "2026-09-19T00:00:00", startTimeUtc = "2026-09-19T14:16:12.9574126", chapters = {
            { chapterId = 11312, startTimeUtc = "2026-09-19T14:16:12.9574126", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7461, localDate = "2026-09-19T00:00:00", startTimeUtc = "2026-09-19T13:33:23.8175739", chapters = {
            { chapterId = 11312, startTimeUtc = "2026-09-19T13:33:23.8175739", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7461, localDate = "2026-09-19T00:00:00", startTimeUtc = "2026-09-19T13:01:57.6991072", chapters = {
            { chapterId = 11312, startTimeUtc = "2026-09-19T13:01:57.6991072", durationSeconds = 102, pagesRead = 0 } } },
    { seriesId = 7461, localDate = "2026-09-19T00:00:00", startTimeUtc = "2026-09-19T10:51:52.8573558", chapters = {
            { chapterId = 11312, startTimeUtc = "2026-09-19T10:51:52.8573558", durationSeconds = 445, pagesRead = 0 } } },
    { seriesId = 7461, localDate = "2026-09-19T00:00:00", startTimeUtc = "2026-09-19T09:58:37.3332857", chapters = {
            { chapterId = 11312, startTimeUtc = "2026-09-19T09:58:37.3332857", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7461, localDate = "2026-09-19T00:00:00", startTimeUtc = "2026-09-19T06:19:27.9750172", chapters = {
            { chapterId = 11312, startTimeUtc = "2026-09-19T06:19:27.9750172", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7461, localDate = "2026-09-19T00:00:00", startTimeUtc = "2026-09-19T05:44:36.041471", chapters = {
            { chapterId = 11312, startTimeUtc = "2026-09-19T05:44:36.041471", durationSeconds = 500, pagesRead = 0 } } },
    { seriesId = 7461, localDate = "2026-09-19T00:00:00", startTimeUtc = "2026-09-19T05:08:30.2036102", chapters = {
            { chapterId = 11312, startTimeUtc = "2026-09-19T05:08:30.2036102", durationSeconds = 263, pagesRead = 4 } } },
    { seriesId = 7560, localDate = "2026-09-19T00:00:00", startTimeUtc = "2026-09-19T04:47:13.2207635", chapters = {
            { chapterId = 11430, startTimeUtc = "2026-09-19T04:47:13.2207635", durationSeconds = 1, pagesRead = 1 } } },
    { seriesId = 7556, localDate = "2026-09-19T00:00:00", startTimeUtc = "2026-09-19T04:07:25.0646351", chapters = {
            { chapterId = 11426, startTimeUtc = "2026-09-19T04:07:25.0646351", durationSeconds = 0, pagesRead = 1 } } },
    { seriesId = 7561, localDate = "2026-09-19T00:00:00", startTimeUtc = "2026-09-19T03:29:58.6171005", chapters = {
            { chapterId = 11438, startTimeUtc = "2026-09-19T03:29:58.6171005", durationSeconds = 5, pagesRead = 4 } } },
    { seriesId = 7461, localDate = "2026-09-19T00:00:00", startTimeUtc = "2026-09-19T02:37:58.1533148", chapters = {
            { chapterId = 11312, startTimeUtc = "2026-09-19T02:37:58.1533148", durationSeconds = 524, pagesRead = 0 } } },
    { seriesId = 7461, localDate = "2026-09-19T00:00:00", startTimeUtc = "2026-09-19T02:00:00.8956888", chapters = {
            { chapterId = 11312, startTimeUtc = "2026-09-19T02:00:00.8956888", durationSeconds = 524, pagesRead = 1 } } },
    { seriesId = 7461, localDate = "2026-09-18T00:00:00", startTimeUtc = "2026-09-18T13:54:08.9566107", chapters = {
            { chapterId = 11312, startTimeUtc = "2026-09-18T13:54:08.9566107", durationSeconds = 174, pagesRead = 0 } } },
    { seriesId = 7461, localDate = "2026-09-18T00:00:00", startTimeUtc = "2026-09-18T12:53:09.8665339", chapters = {
            { chapterId = 11312, startTimeUtc = "2026-09-18T12:53:09.8665339", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7461, localDate = "2026-09-18T00:00:00", startTimeUtc = "2026-09-18T09:50:06.0469366", chapters = {
            { chapterId = 11312, startTimeUtc = "2026-09-18T09:50:06.0469366", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7461, localDate = "2026-09-18T00:00:00", startTimeUtc = "2026-09-18T09:25:33.4181389", chapters = {
            { chapterId = 11312, startTimeUtc = "2026-09-18T09:25:33.4181389", durationSeconds = 738, pagesRead = 1 } } },
    { seriesId = 7490, localDate = "2026-09-18T00:00:00", startTimeUtc = "2026-09-18T07:52:05.2045118", chapters = {
            { chapterId = 11335, startTimeUtc = "2026-09-18T07:52:05.2045118", durationSeconds = 6, pagesRead = 2 } } },
    { seriesId = 7476, localDate = "2026-09-18T00:00:00", startTimeUtc = "2026-09-18T06:59:54.0156885", chapters = {
            { chapterId = 11317, startTimeUtc = "2026-09-18T06:59:54.0156885", durationSeconds = 2, pagesRead = 2 } } },
    { seriesId = 7461, localDate = "2026-09-18T00:00:00", startTimeUtc = "2026-09-18T06:47:37.6019707", chapters = {
            { chapterId = 11312, startTimeUtc = "2026-09-18T06:47:37.6019707", durationSeconds = 0, pagesRead = 0 } } },
}
