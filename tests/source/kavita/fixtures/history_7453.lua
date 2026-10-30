--[[--
样本 fixture：`GET /api/Stats/reading-history/series/7453` 实测响应（2026-10-16，Kavita 0.9.1.4）
的精简版，只留聚合用到的字段（seriesId / localDate / startTimeUtc / chapters[]）。

对账基线（research-kavita-stats-pull.md §3）：64 条会话 / 14,237s；逐日见 stats_spec 用例。
来源完整响应：/tmp/opencode/kavita/live/history-7453-all.json（提交时精简，数值逐条未改）。

@module tests.extensions.kavita.fixtures.history_7453
--]]
return {
    { seriesId = 7453, localDate = "2026-10-15T00:00:00", startTimeUtc = "2026-10-15T13:49:02.6722926", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-15T13:49:02.6722926", durationSeconds = 845, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-15T00:00:00", startTimeUtc = "2026-10-15T11:51:10.7006183", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-15T11:51:10.7006183", durationSeconds = 638, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-15T00:00:00", startTimeUtc = "2026-10-15T11:14:33.5066159", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-15T11:14:33.5066159", durationSeconds = 436, pagesRead = 0 } } },
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
    { seriesId = 7453, localDate = "2026-10-14T00:00:00", startTimeUtc = "2026-10-14T13:55:48.5704762", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-14T13:55:48.5704762", durationSeconds = 716, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-14T00:00:00", startTimeUtc = "2026-10-14T12:59:54.4012612", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-14T12:59:54.4012612", durationSeconds = 210, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-14T00:00:00", startTimeUtc = "2026-10-14T12:32:09.2873459", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-14T12:32:09.2873459", durationSeconds = 354, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-14T00:00:00", startTimeUtc = "2026-10-14T10:50:12.8325335", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-14T10:50:12.8325335", durationSeconds = 427, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-14T00:00:00", startTimeUtc = "2026-10-14T09:55:45.2531997", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-14T09:55:45.2531997", durationSeconds = 229, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-14T00:00:00", startTimeUtc = "2026-10-14T08:18:25.5482677", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-14T08:18:25.5482677", durationSeconds = 631, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-14T00:00:00", startTimeUtc = "2026-10-14T06:35:44.8950968", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-14T06:56:37.9521487", durationSeconds = 597, pagesRead = 5 },
            { chapterId = 11273, startTimeUtc = "2026-10-14T06:35:44.8950968", durationSeconds = 529, pagesRead = -6 } } },
    { seriesId = 7453, localDate = "2026-10-14T00:00:00", startTimeUtc = "2026-10-14T06:12:27.3026502", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-14T06:12:27.3026502", durationSeconds = 686, pagesRead = 1 } } },
    { seriesId = 7453, localDate = "2026-10-14T00:00:00", startTimeUtc = "2026-10-14T05:35:38.8926445", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-14T05:35:38.8926445", durationSeconds = 674, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-14T00:00:00", startTimeUtc = "2026-10-14T03:36:59.7411875", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-14T03:36:59.7411875", durationSeconds = 1352, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-14T00:00:00", startTimeUtc = "2026-10-14T01:39:31.4453653", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-14T01:39:31.4453653", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-13T00:00:00", startTimeUtc = "2026-10-13T14:56:50.7578846", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-13T14:56:50.7578846", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-13T00:00:00", startTimeUtc = "2026-10-13T12:50:13.6195947", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-13T12:50:13.6195947", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-13T00:00:00", startTimeUtc = "2026-10-13T10:49:24.2700176", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-13T10:49:24.2700176", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-13T00:00:00", startTimeUtc = "2026-10-13T09:19:44.4142404", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-13T09:19:44.4142404", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-13T00:00:00", startTimeUtc = "2026-10-13T07:17:51.0855549", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-13T07:17:51.0855549", durationSeconds = 31, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-13T00:00:00", startTimeUtc = "2026-10-13T06:23:56.2429684", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-13T06:23:56.2429684", durationSeconds = 948, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-13T00:00:00", startTimeUtc = "2026-10-13T04:44:11.1456271", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-13T04:44:11.1456271", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-13T00:00:00", startTimeUtc = "2026-10-13T04:04:52.1419963", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-13T04:04:52.1419963", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-12T00:00:00", startTimeUtc = "2026-10-12T03:52:47.3926019", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-12T03:52:47.3926019", durationSeconds = 0, pagesRead = 0 } } },
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
    { seriesId = 7453, localDate = "2026-10-10T00:00:00", startTimeUtc = "2026-10-10T04:44:42.7023417", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-10T04:44:42.7023417", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-10T00:00:00", startTimeUtc = "2026-10-10T03:55:35.74839", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-10T03:55:35.74839", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-10T00:00:00", startTimeUtc = "2026-10-10T03:39:55.2030981", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-10T03:39:55.2030981", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-09T00:00:00", startTimeUtc = "2026-10-09T14:45:39.0731175", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-09T14:45:39.0731175", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-09T00:00:00", startTimeUtc = "2026-10-09T07:44:06.636679", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-09T07:44:06.636679", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-09T00:00:00", startTimeUtc = "2026-10-09T07:13:20.7857153", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-09T07:13:20.7857153", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-09T00:00:00", startTimeUtc = "2026-10-09T04:40:28.7189645", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-09T04:40:28.7189645", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-09T00:00:00", startTimeUtc = "2026-10-09T04:05:17.6951039", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-09T04:05:17.6951039", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-08T00:00:00", startTimeUtc = "2026-10-08T14:34:05.7981443", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-08T14:34:05.7981443", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-08T00:00:00", startTimeUtc = "2026-10-08T13:12:53.6969824", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-08T13:12:53.6969824", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-08T00:00:00", startTimeUtc = "2026-10-08T11:48:06.6315963", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-08T11:48:06.6315963", durationSeconds = 544, pagesRead = 0 } } },
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
    { seriesId = 7453, localDate = "2026-10-08T00:00:00", startTimeUtc = "2026-10-08T04:05:45.0300961", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-08T04:05:45.0300961", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-07T00:00:00", startTimeUtc = "2026-10-07T13:44:15.125016", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-07T13:44:15.125016", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-07T00:00:00", startTimeUtc = "2026-10-07T09:45:01.0814021", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-07T09:45:01.0814021", durationSeconds = 0, pagesRead = 0 } } },
    { seriesId = 7453, localDate = "2026-10-07T00:00:00", startTimeUtc = "2026-10-07T05:19:38.9892914", chapters = {
            { chapterId = 11273, startTimeUtc = "2026-10-07T05:19:38.9892914", durationSeconds = 503, pagesRead = 0 } } },
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
    { seriesId = 7453, localDate = "2026-09-29T00:00:00", startTimeUtc = "2026-09-29T10:25:25.4088288", chapters = {
            { chapterId = 11271, startTimeUtc = "2026-09-29T10:25:25.4088288", durationSeconds = 86, pagesRead = 2 } } },
    { seriesId = 7453, localDate = "2026-09-29T00:00:00", startTimeUtc = "2026-09-29T10:01:44.7835505", chapters = {
            { chapterId = 11271, startTimeUtc = "2026-09-29T10:01:44.7835505", durationSeconds = 230, pagesRead = 0 } } },
}
