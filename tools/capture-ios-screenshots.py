"""Capture the unchanged app using a disposable Simulator RSS library.

Only the simulator's app data is seeded. No screenshot mode or fixture code is
compiled into the app. News titles/dates/images come from the public RSS sources
recorded in sources.json; these are not the user's subscriptions.
"""
import copy
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


def run(*args, timeout=180):
    print("Running:", " ".join(args), flush=True)
    try:
        return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT, timeout=timeout).strip()
    except subprocess.CalledProcessError as error:
        print(error.output, flush=True)
        raise


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
            print("Loading RSS:", source, flush=True)
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
            for item in channel.findall("item")[:6]:
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


def seed_library(udid, app, bundle, library):
    container = pathlib.Path(run("xcrun", "simctl", "get_app_container", udid, bundle, "data"))
    directory = container / "Documents" / "Nook"
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "NookLibrary.json").write_text(json.dumps(library), encoding="utf-8")


def capture_test(udid, derived, output, name, method):
    result = output / (name + ".xcresult")
    args = ["xcodebuild", "test-without-building", "-project", "Nook.xcodeproj", "-scheme", "NookScreenshots",
            "-destination", "id=" + udid, "-derivedDataPath", str(derived),
            "-parallel-testing-enabled", "NO", "-maximum-concurrent-test-simulator-destinations", "1",
            "-only-testing:NookiOSUITests/NewsHomeScreenshotTests/" + method,
            "-resultBundlePath", str(result), "-skipPackagePluginValidation", "CODE_SIGNING_ALLOWED=NO"]
    print("UI capture:", name, flush=True)
    try:
        with (output / (name + ".log")).open("w", encoding="utf-8") as log:
            subprocess.run(args, stdout=log, stderr=subprocess.STDOUT, timeout=900, check=True)
    finally:
        if result.exists():
            exported = output / (name + "-attachments")
            print(run("xcrun", "xcresulttool", "export", "attachments", "--path", str(result),
                      "--output-path", str(exported)), flush=True)


def main():
    app, output = map(pathlib.Path, sys.argv[1:])
    output.mkdir(parents=True, exist_ok=True)
    derived = app.parents[3]
    bundle = run("/usr/libexec/PlistBuddy", "-c", "Print CFBundleIdentifier", str(app / "Info.plist"))
    library = rss_library(output)
    devices = json.loads(run("xcrun", "simctl", "list", "devices", "available", "--json"))["devices"]
    (output / "devices.json").write_text(json.dumps(devices, indent=2), encoding="utf-8")
    compatible = [device for runtime, entries in sorted(devices.items(), reverse=True)
                  if "iOS-26" in runtime for device in entries if device.get("isAvailable")]
    # Match the phase 2 screenshot dimensions exactly.
    selected = [next(d for d in compatible if d["name"] == "iPhone 17 Pro"),
                next(d for d in compatible if d["name"] == "iPad Pro 13-inch (M5)")]
    for device, label in zip(selected, ["iphone", "ipad"]):
        udid = device["udid"]
        print("Booting", device["name"], flush=True)
        if device["state"] != "Booted":
            run("xcrun", "simctl", "boot", udid)
        print(run("xcrun", "simctl", "bootstatus", udid, "-b", timeout=600), flush=True)
        run("xcrun", "simctl", "install", udid, str(app))
        seed_library(udid, app, bundle, library)
        run("xcrun", "simctl", "status_bar", udid, "override", "--time", "9:41", "--batteryState", "charged", "--batteryLevel", "100")
        run("xcrun", "simctl", "ui", udid, "appearance", "light")
        if label == "iphone":
            capture_test(udid, derived, output, "iphone-light", "testEditorialSectionsAndScroll")
            run("xcrun", "simctl", "ui", udid, "appearance", "dark")
            capture_test(udid, derived, output, "iphone-dark", "testDarkMode")
            run("xcrun", "simctl", "ui", udid, "appearance", "light")
            # The no-image case changes only disposable simulator input data.
            # It exercises production image fallback without a special UI mode.
            run("xcrun", "simctl", "uninstall", udid, bundle)
            run("xcrun", "simctl", "install", udid, str(app))
            typography = copy.deepcopy(library)
            for article in typography["articles"]:
                article.pop("heroImageURL", None)
                article.pop("heroImageProvenance", None)
                article["rssImages"] = []
            seed_library(udid, app, bundle, typography)
            capture_test(udid, derived, output, "iphone-typography", "testTypographyHero")
        else:
            capture_test(udid, derived, output, "ipad-light", "testIPad")
        run("xcrun", "simctl", "shutdown", udid)
    (output / "capture.json").write_text(json.dumps(dict(devices=selected, articles=len(library["articles"]),
        note="Real Simulator screenshots; public RSS preview library. Typography case removes only fixture image metadata."), indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
