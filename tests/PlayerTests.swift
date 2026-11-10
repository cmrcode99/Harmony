import Foundation
import JavaScriptCore

@main struct PlayerTests {
    static func main() throws {
        let html = try String(contentsOfFile: "player.html", encoding: .utf8)
        guard let start = html.range(of: "<script>"),
              let end = html.range(of: "</script>", range: start.upperBound..<html.endIndex) else { fatalError("Missing player script") }
        let context = JSContext()!
        var failure: String?
        context.exceptionHandler = { _, error in failure = error?.toString() ?? "JavaScript error" }
        context.evaluateScript("""
        var events = {}, order = [], messages = [];
        var loadCount=0, fakeStatus={hidden:true,textContent:''};
        var fakeVideo = {paused:true,currentTime:0,duration:100,volume:0.7,muted:true,style:{}, load:function(){loadCount++;this.currentTime=0;this.duration=NaN;this.paused=true;}, setAttribute:function(){}, pause:function(){this.paused=true;order.push('pause');}, play:function(){this.paused=false;order.push('play');return Promise.resolve();}, addEventListener:function(n,f){events[n]=f;}};
        var window = {webkit:{messageHandlers:{togglePlayback:{postMessage:function(m){order.push('message');messages.push(m);}}}}};
        var document = {querySelector:function(s){return s==='video'?fakeVideo:fakeStatus;}};
        function check(value,message){if(!value)throw new Error(message);}
        function completeLoad(){fakeVideo.duration=600;events.loadedmetadata();events.seeked();}
        """)
        let playlist = try String(contentsOfFile: "media/playlist.json", encoding: .utf8)
        context.evaluateScript("window.harmonyPlaylist = " + playlist + ";")
        context.evaluateScript(String(html[start.upperBound..<end.lowerBound]))
        context.evaluateScript("""
        window.harmonySkipVideo();
        check(loadCount===0,'Skip ran before initialization');
        window.harmonyApplyPlayback(false,0,true,1);
        check(fakeVideo.paused && fakeVideo.style.visibility==='hidden','Intro played before the trim seek');
        fakeVideo.duration=600;events.loadedmetadata();
        check(fakeVideo.currentTime===120 && fakeVideo.paused && fakeVideo.style.visibility==='hidden','Intro was exposed before seek completion');
        events.seeked();
        check(!fakeVideo.paused && fakeVideo.style.visibility==='visible','Trimmed playback failed to start');
        events.pointerdown({button:0,isPrimary:true});
        check(order.slice(-2).join(',')==='pause,message','Pause waited for native round trip');
        events.click({detail:1});
        check(messages.length===1,'Pointer click toggled twice');
        window.harmonyApplyPlayback(false,0,true,1);
        check(fakeVideo.paused,'Stale update undid pause');
        events.pointerdown({button:0,isPrimary:true});
        check(order.slice(-2).join(',')==='play,message','Resume waited for native round trip');
        window.harmonyApplyPlayback(true,1,true,1);
        check(!fakeVideo.paused,'Old acknowledgement undid newer click');
        window.harmonyApplyPlayback(false,2,false,1);
        check(fakeVideo.paused,'Hidden video playing');
        window.harmonyApplyPlayback(false,2,true,1);
        check(!fakeVideo.paused,'Visible video failed to resume');
        events.keydown({key:'Enter',repeat:false,preventDefault:function(){}});
        check(fakeVideo.paused,'Keyboard pause failed');
        events.keydown({key:'Enter',repeat:true,preventDefault:function(){}});
        check(fakeVideo.paused,'Held key toggled repeatedly');
        window.harmonyApplyPlayback(true,3,false,1);
        window.harmonyApplyPlayback(true,3,true,1);
        check(fakeVideo.paused,'Hide/unhide cleared intentional pause');
        fakeVideo.currentTime=77;fakeVideo.volume=0.37;fakeVideo.muted=false;
        window.harmonySkipVideo();
        check(window.harmonyPlaybackSnapshot()===null,'Old metadata survived a track change');
        completeLoad();
        check(window.harmonyTrackIndex===1 && fakeVideo.currentTime===120,'Skip failed to move/reset trimmed position');
        check(fakeVideo.paused && fakeVideo.volume===0.37 && !fakeVideo.muted,'Skip changed intentional pause/audio');
        check(messages[messages.length-1].index===1,'Track change was not sent to native state');
        window.harmonyApplyPlayback(false,3,true,1,0);
        check(fakeVideo.paused && window.harmonyTrackIndex===1,'Stale native update undid track/pause');
        events.pointerdown({button:0,isPrimary:true});
        window.harmonySkipVideo(2);
        completeLoad();
        check(window.harmonyTrackIndex===3 && !fakeVideo.paused,'Batched skips lost clicks or playback');
        window.harmonySkipVideo();
        completeLoad();
        check(window.harmonyTrackIndex===0,'Playlist failed to wrap');
        fakeVideo.paused=true;events.ended();completeLoad();
        check(window.harmonyTrackIndex===1 && !fakeVideo.paused,'Natural ending did not advance');
        var latest=messages[messages.length-1].revision;
        window.harmonyApplyPlayback(false,latest,false,1,0);
        window.harmonySkipVideo();completeLoad();
        check(fakeVideo.paused,'Skip/metadata resumed a hidden video');
        window.harmonyApplyPlayback(true,0,true,2,2);
        completeLoad();
        check(window.harmonyTrackIndex===2 && fakeVideo.paused,'Page reload lost selected video/pause');
        fakeVideo.duration=243;fakeVideo.currentTime=137;
        check(window.harmonyPlaybackSnapshot().join(',')==='17,123,2,0','Snapshot lost source identity/revision');
        window.harmonySeekPlayback(-5,2);
        check(fakeVideo.currentTime===120,'Scrubbing reentered the cut intro');
        window.harmonySeekPlayback(9999,2);
        check(fakeVideo.currentTime===243,'Scrubbing exceeded the retained clip');
        window.harmonySeekPlayback(10,1);
        check(fakeVideo.currentTime===243,'A stale seek changed a different video');
        var before=loadCount;
        window.harmonySkipVideo(0);window.harmonySkipVideo(-1);window.harmonySkipVideo(NaN);
        check(loadCount===before,'Invalid skip changed source');
        for(var i=0;i<window.harmonyPlaylist.length;i++) events.error();
        check(!fakeStatus.hidden && fakeVideo.paused,'All-file failure did not show a stopped state');
        before=loadCount;events.error();events.loadedmetadata();
        check(loadCount===before && fakeVideo.paused,'Media errors created an endless retry loop');
        window.harmonySkipVideo();
        completeLoad();
        check(fakeStatus.hidden && window.harmonyTrackIndex===2 && fakeVideo.paused,'Manual skip could not recover without changing pause');
        """)
        if let failure = failure { fatalError(failure) }
        print("PASS player: pause/state ordering, keyboard, playlist wrap/end/skip, pause/audio/visibility, two-minute trim without intro flashes, relative scrub bounds, source snapshots and bounded error recovery")
    }
}
