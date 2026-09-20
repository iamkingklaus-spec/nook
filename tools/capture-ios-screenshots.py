"""Capture the unchanged app using a disposable Simulator RSS library.

Only the simulator's app data is seeded. No screenshot mode or fixture code is
compiled into the app. News titles/dates/images come from the public RSS sources
recorded in sources.json; these are not the user's subscriptions.
"""
import datetime as dt
import email.utils
import hashlib
import html
import json
import pathlib
import re
import subprocess
import sys
import time
import urllib.request
import xml.etree.ElementTree as ET


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def iso(date):
    return date.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def rss_library(output):
    sources = [
        "https://feeds.bbci.co.uk/news/world/rss.xml",
        "https://feeds.bbci.co.uk/news/business/rss.xml",
        "https://feeds.bbci.co.uk/news/technology/rss.xml",
        "https://feeds.bbci.co.uk/news/science_and_environment/rss.xml",
        "https://www.theguardian.com/culture/rss",
    ]
    feeds, articles, diagnostics = [], [], []
    for source in sources:
        try:
            request = urllib.request.Request(source, headers={"User-Agent": "Nook-Simulator-Preview/1.0"})
            with urllib.request.urlopen(request, timeout=30) as response:
                data = response.read()
            channel = ET.fromstring(data).find("channel")
            if channel is None:
                raise ValueError("Missing RSS channel")
            feed_id = hashlib.sha256(source.encode()).hexdigest()[:16]
            feeds.append(dict(id=feed_id, title=channel.findtext("title", "RSS"),
                              siteDescription="", category="Feeds", systemImage="newspaper",
                              feedURL=source, siteURL=channel.findtext("link", source), healthScore=1))
            for item in channel.findall("item")[:20]:
                link = item.findtext("link")
                if not link:
                    continue
                guid = item.findtext("guid", link)
                date = email.utils.parsedate_to_datetime(item.findtext("pubDate"))
                summary = html.unescape(re.sub(r"<[^>]+>", "", item.findtext("description", "")))
                images = []
                for element in item.iter():
                    if element.tag in ("{http://search.yahoo.com/mrss/}thumbnail", "{http://search.yahoo.com/mrss/}content"):
                        url = element.get("url", "")
                        if url.startswith(("https://", "http://")):
                            provenance = "mediaThumbnail" if element.tag.endswith("thumbnail") else "mediaContent"
                            images.append(dict(url=url, provenance=provenance))
                article = dict(id=feed_id + "#" + guid, feedID=feed_id,
                               title=item.findtext("title", ""), summary=summary[:500], bodyParagraphs=[summary],
                               publishedAt=iso(date), url=link, estimatedReadMinutes=3,
                               isRead=False, isStarred=False, feedItemGUID=guid,
                               rssTags=[tag.text for tag in item.findall("category") if tag.text], rssImages=images)
                if images:
                    article.update(heroImageURL=images[0]["url"], heroImageProvenance=images[0]["provenance"])
                articles.append(article)
            diagnostics.append(dict(url=source, status="imported"))
        except Exception as error:
            diagnostics.append(dict(url=source, status="failed", error=str(error)))
    (output / "sources.json").write_text(json.dumps(diagnostics, indent=2), encoding="utf-8")
    if not articles:
        raise RuntimeError("No RSS articles loaded; refusing to pass an empty screenshot as a news preview")
    return dict(feeds=feeds, articles=articles, folders=[], lastRefreshedAt=iso(dt.datetime.now(dt.timezone.utc)))


def main():
    app, output = map(pathlib.Path, sys.argv[1:])
    output.mkdir(parents=True, exist_ok=True)
    bundle = run("/usr/libexec/PlistBuddy", "-c", "Print CFBundleIdentifier", str(app / "Info.plist"))
    library = rss_library(output)
    devices = json.loads(run("xcrun", "simctl", "list", "devices", "available", "--json"))["devices"]
    (output / "devices.json").write_text(json.dumps(devices, indent=2), encoding="utf-8")
    compatible = [device for runtime, entries in sorted(devices.items(), reverse=True)
                  if "iOS-26" in runtime for device in entries if device.get("isAvailable")]
    selected = [next(d for d in compatible if "iPhone" in d["name"]),
                next(d for d in compatible if "iPad" in d["name"])]
    for device, label in zip(selected, ["iphone", "ipad"]):
        udid = device["udid"]
        if device["state"] != "Booted":
            run("xcrun", "simctl", "boot", udid)
        run("xcrun", "simctl", "bootstatus", udid, "-b")
        run("xcrun", "simctl", "install", udid, str(app))
        container = pathlib.Path(run("xcrun", "simctl", "get_app_container", udid, bundle, "data"))
        directory = container / "Documents" / "Nook"
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "NookLibrary.json").write_text(json.dumps(library), encoding="utf-8")
        run("xcrun", "simctl", "status_bar", udid, "override", "--time", "9:41", "--batteryState", "charged", "--batteryLevel", "100")
        run("xcrun", "simctl", "ui", udid, "appearance", "light")
        flags = ["hasCompletedWelcome", "seenReaderGestureHint", "seenListTapHint", "seenFeedsAddHint",
                 "seenSyncFolderHint", "translateTitlesPromoSeen", "usesLocalLibrary"]
        args = [part for flag in flags for part in ("-" + flag, "YES")]
        run("xcrun", "simctl", "launch", udid, bundle, *args, "-autoRefreshEnabled", "NO")
        time.sleep(35)  # Allow local migration, splash, and remote RSS images to settle.
        run("xcrun", "simctl", "io", udid, "screenshot", str(output / (label + "-home-light.png")))
        if label == "iphone":
            run("xcrun", "simctl", "ui", udid, "appearance", "dark")
            time.sleep(3)
            run("xcrun", "simctl", "io", udid, "screenshot", str(output / "iphone-home-dark.png"))
        run("xcrun", "simctl", "shutdown", udid)
    (output / "capture.json").write_text(json.dumps(dict(devices=selected, articles=len(library["articles"]),
        note="Real Simulator screenshots; public RSS preview library, not personal user data."), indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
