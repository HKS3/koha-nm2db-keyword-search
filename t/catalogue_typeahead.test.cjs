const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");
const vm = require("node:vm");

// Exercise the JavaScript actually shipped by the plugin, without loading Koha
// or accessing a database. This is a DOM stub, not a browser compatibility test.
const source = readFileSync(path.join(__dirname,
    "../Koha/Plugin/HKS3/NM2DBKeywordSearch.pm"), "utf8");
const script = source.match(/my \$script = <<'JS';\s*<script>([\s\S]*?)<\/script>\s*JS/)[1];

function setup(suggestions, searchPath = "/cgi-bin/koha/opac-search.pl") {
    const requests = [];
    const timers = new Map();
    const listeners = {};
    const input = {
        value: "",
        dataset: {},
        attributes: {},
        setAttribute(name, value) { this.attributes[name] = value; },
        insertAdjacentElement(position, element) { this.datalist = element; },
        addEventListener(name, callback) { listeners[name] = callback; },
    };
    const form = {
        dataset: {},
        getAttribute() { return searchPath; },
        querySelectorAll() { return [input]; },
    };
    let timerId = 0;
    const context = {
        URL, URLSearchParams, AbortController,
        window: {
            location: { href: `http://nm2dbmaster.localhost:8080${searchPath}` },
            setTimeout(callback) { timers.set(++timerId, callback); return timerId; },
            clearTimeout(id) { timers.delete(id); },
        },
        document: {
            readyState: "complete",
            documentElement: {},
            querySelectorAll() { return [form]; },
            createElement() { return { innerHTML: "" }; },
        },
        MutationObserver: class { observe() {} },
        fetch: async (url) => {
            requests.push(url);
            return { ok: true, json: async () => ({ suggestions }) };
        },
    };
    vm.runInNewContext(script.replace("__CONFIG__", JSON.stringify({
        searchPath, suggestionsUrl: "/suggestions", minChars: 2, limit: 10,
    })), context);
    return {
        input, requests,
        async fire(event, value) {
            input.value = value;
            assert.equal(typeof listeners[event], "function", `${event} listener is registered`);
            listeners[event]({ inputType: "insertText" });
            for (const callback of timers.values()) callback();
            timers.clear();
            await new Promise(setImmediate);
        },
    };
}

for (const searchPath of ["/cgi-bin/koha/opac-search.pl", "/cgi-bin/koha/catalogue/search.pl"]) {
    test(`${searchPath}: Firefox labels contain the searchable title`, async () => {
        const app = setup([{ value: "Spechte & Co. :", field: "245$a", count: 1, biblionumber: 81514 }], searchPath);
        await app.fire("input", "specht");
        assert.equal(app.requests[0], "/suggestions?term=specht&limit=10");
        assert.match(app.input.datalist.innerHTML, /value="Spechte &amp; Co\. :"/);
        assert.match(app.input.datalist.innerHTML, /label="Spechte &amp; Co\. :[^\"]*245\$a #81514 \(1\)"/);
    });
}

test("titles and metadata remain HTML-escaped", async () => {
    const app = setup([{ value: 'Specht "<test>" & Co.', field: '<245$a>', count: 1 }]);
    await app.fire("input", "specht");
    assert.match(app.input.datalist.innerHTML, /label="Specht &quot;&lt;test&gt;&quot; &amp; Co\.[^\"]*&lt;245\$a&gt;/);
    assert.doesNotMatch(app.input.datalist.innerHTML, /<test>|<245\$a>/);
});

test("focusing a prefilled field requests suggestions, but short terms do not", async () => {
    const app = setup([{ value: "Spechte", field: "245$a", count: 1 }]);
    await app.fire("focus", "specht");
    assert.equal(app.requests.length, 1);
    assert.match(app.input.datalist.innerHTML, /Spechte/);
    await app.fire("input", "s");
    assert.equal(app.requests.length, 1);
    assert.equal(app.input.datalist.innerHTML, "");
});
