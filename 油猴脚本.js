// ==UserScript==
// @name         Infi Menu & Merchant Locations SVG Tree (V11.2 Item节点显示Menu功能)
// @namespace    http://tampermonkey.net/
// @version      11.3
// @description  Ctrl+点击节点复制时带入队标记（clipboard_v1 识别）；普通点击/Ctrl+C 不影响队列。
// @author       You
// @match        *://*.orderwithinfi.com/*
// @require      https://d3js.org/d3.v7.min.js
// @grant        none
// @run-at       document-start
// ==/UserScript==

(function() {
    'use strict';

    // ==========================================
    // 🎨 【全局自定义颜色配置区】
    // ==========================================
    const LINK_COLOR = "#ff0055";           // 左侧 Location 连线颜色
    const MENU_LINK_COLOR = "#ff0055";      // 右侧 Menu 连线颜色
    const ITEMS_LINK_COLOR = "#ff0055";     // Items Library 连线高亮色（赛博霓虹青）
    const COUNT_COLOR = "#999999";          // 节点 [数量] 颜色
    const STRIKE_COLOR = "#d946ef";         // is_active=false 的中划线颜色
    const PRICE_COLOR = "#10b981";          // Item/Mod/Var 价格颜色

    console.log("🚀 [Infi Merchant 脚本] V11.0 三面板版启动！");

    window.__infiMerchantPayload = null;
    window.__infiMenuPayload = null;

    let leftSearchKeyword = "";
    let isLeftRegexMode = true;
    let isLeftCaseSensitive = false;

    let rightSearchKeyword = "";
    let isRightRegexMode = true;
    let isRightCaseSensitive = false;
    window.__infiShowSubItems = false;

    let isPanelLocked = false;
    let currentHoveredData = null;

    let drawLocationTreeRef = null;
    let drawMenuTreeRef = null;

    window.__infiLastLeftKeyword = "";
    window.__infiLastRightKeyword = "";
    window.__infiForceMenuAutoCenter = false;
    window.__infiShowLocationMenus = false;   // "细节" toggle for Location panel
    window.__infiLocDetailAutoCenter = false; // auto-center flag for Location detail toggle
    window.__infiVariationPlatformMap = {};   // variation_id → platform (from get-products/{locId})
    window.__infiCurrentLocationId = null;    // location ID for the currently viewed menu
    window.__infiMenuToLocationMap = {};      // menu_id → location_id (built from location/menu intercepts)
    window.__infiLiveHeaders = {};            // in-memory auth headers captured from current page session (takes priority over localStorage cache)

    // ==========================================
    // Items Library (third panel) global state
    // ==========================================
    window.__infiItemsPayload = null;
    window.__infiModifierSetsMap = {};
    window.__infiItemsLoaded = false;
    window.__infiModifierSetsLoaded = false;
    window.__infiShowItemsSubItems = false;
    window.__infiItemsForceAutoCenter = false;
    window.__infiItemsDetailAutoCenter = false;
    let itemsSearchKeyword = "";
    let isItemsRegexMode = true;
    let isItemsCaseSensitive = false;
    let drawItemsTreeRef = null;
    window.__infiLastItemsKeyword = "";

    // ==========================================
    // 0. 全局按键监听 (彻底修复 Ctrl 消失 Bug)
    // ==========================================
    window.addEventListener('keydown', (e) => {
        if (e.key === 'Control' && !e.repeat) {
            const tp = document.getElementById("infim-tooltip-panel");
            if (!tp) return;

            if (tp.style.display === 'none' && !isPanelLocked) return;

            isPanelLocked = !isPanelLocked;
            const indicator = document.getElementById("infim-lock-indicator");
            if (isPanelLocked) {
                tp.style.borderColor = "#52c41a";
                tp.style.boxShadow = "-4px 4px 15px rgba(82, 196, 26, 0.15)";
                tp.style.pointerEvents = "auto";
                if (indicator) indicator.style.display = "block";
            } else {
                tp.style.borderColor = "rgba(0, 0, 0, 0.05)";
                tp.style.boxShadow = "-4px 4px 15px rgba(0, 0, 0, 0.08)";
                tp.style.pointerEvents = "none";
                if (indicator) indicator.style.display = "none";
                if (!currentHoveredData) tp.style.display = 'none';
            }
        }
    });

    window.addEventListener('keydown', async (e) => {
        if (e.key === 'F1') {
            if (!checkCurrentURL()) return;
            e.preventDefault(); e.stopPropagation();

            const overlay = document.getElementById('infi-merchant-overlay');
            if (overlay) {
                overlay.style.display = overlay.style.display === 'none' ? 'block' : 'none';
                if (overlay.style.display === 'block') {
                    const lastView = localStorage.getItem('__infi_last_active_view') || 'left';
                    slideView(lastView);
                    if (drawLocationTreeRef) drawLocationTreeRef();

                    if (!window.__infiMenuPayload) {
                        const localData = localStorage.getItem('__infi_last_menu_payload');
                        if (localData) window.__infiMenuPayload = JSON.parse(localData);
                    }
                    if (window.__infiMenuPayload && drawMenuTreeRef) drawMenuTreeRef();
                }
            } else {
                buildDualViewUI();

                let activePayload = window.__infiMerchantPayload;
                if (!activePayload) {
                    const localData = localStorage.getItem('__infi_last_merchant_payload');
                    if (localData) { activePayload = JSON.parse(localData); window.__infiMerchantPayload = activePayload; }
                }

                if (activePayload && activePayload.locations && activePayload.locations.length > 0) updateLocationUI(activePayload);
                else executeActiveSnoopRequest();

                if (!window.__infiMenuPayload) {
                    const menuDataStr = localStorage.getItem('__infi_last_menu_payload');
                    if (menuDataStr) window.__infiMenuPayload = JSON.parse(menuDataStr);
                }
                if (window.__infiMenuPayload && drawMenuTreeRef) drawMenuTreeRef();

                const lastView = localStorage.getItem('__infi_last_active_view') || 'left';
                slideView(lastView);
            }
        }
        if (e.key === 'Escape') {
            const overlay = document.getElementById('infi-merchant-overlay');
            if (overlay) overlay.style.display = 'none';
        }
    }, true);

    function autoCenterTree(svg, zoom, focusNodes, duration = 0, minScale = 0.08) {
        if (!focusNodes || focusNodes.length === 0) return;
        const xValues = focusNodes.map(d => d.x);
        const yValues = focusNodes.map(d => d.y);
        const minX = Math.min(...xValues), maxX = Math.max(...xValues);
        const minY = Math.min(...yValues), maxY = Math.max(...yValues);

        const treeWidth = maxY - minY;
        const treeHeight = maxX - minX;

        const viewWidth = window.innerWidth - 420;
        const viewHeight = window.innerHeight - 100;

        const scaleX = viewWidth / (treeWidth || 1);
        const scaleY = viewHeight / (treeHeight || 1);
        let autoScale = Math.min(scaleX, scaleY) * 0.9;
        autoScale = Math.max(minScale, Math.min(1.3, autoScale));

        const centerTreeX = minY + treeWidth / 2;
        const centerTreeY = minX + treeHeight / 2;

        const targetX = (window.innerWidth - 380) / 2 - centerTreeX * autoScale;
        const targetY = window.innerHeight / 2 - centerTreeY * autoScale;

        if (duration > 0) {
            svg.transition().duration(duration).call(zoom.transform, d3.zoomIdentity.translate(targetX, targetY).scale(autoScale));
        } else {
            svg.call(zoom.transform, d3.zoomIdentity.translate(targetX, targetY).scale(autoScale));
        }
    }

    function showToast(message) {
        let toast = document.getElementById("infim-toast");
        if (!toast) {
            toast = document.createElement("div");
            toast.id = "infim-toast";
            toast.style = "position:fixed; top:20px; left:50%; transform:translateX(-50%); background:#ff4d4f; color:#fff; padding:12px 24px; border-radius:8px; z-index:9999999; font-weight:bold; font-family:sans-serif; box-shadow:0 4px 12px rgba(0,0,0,0.15); transition: opacity 0.3s; max-width:80%; word-wrap:break-word; pointer-events:none;";
            document.body.appendChild(toast);
        }
        toast.innerText = message;
        toast.style.display = 'block';
        toast.offsetHeight;
        toast.style.opacity = '1';

        if (toast._timer) clearTimeout(toast._timer);
        toast._timer = setTimeout(() => {
            toast.style.opacity = '0';
            setTimeout(() => { toast.style.display = 'none'; }, 300);
        }, 5000);
    }

    function checkCurrentURL() { return window.location.href.includes('/merchant-portal'); }

    function fetchCurrentAuthToken() {
        let token = localStorage.getItem('token') || sessionStorage.getItem('token') || "";
        if (!token) {
            for (let i = 0; i < localStorage.length; i++) {
                const k = localStorage.key(i);
                if (k.toLowerCase().includes('token') || k.toLowerCase().includes('auth')) {
                    token = localStorage.getItem(k); break;
                }
            }
        }
        if (token && !token.startsWith('Bearer ')) token = 'Bearer ' + token.replace(/^["']|["']$/g, '');
        return token;
    }

    function wipeMerchantCache() {
        console.log("🧹 [Infi Merchant] 检测到登录或商户变更，执行无条件强制清场 ok");
        window.__infiMerchantPayload = null;
        window.__infiMenuPayload = null;
        window.__infiItemsPayload = null;
        window.__infiModifierSetsMap = {};
        window.__infiItemsLoaded = false;
        window.__infiModifierSetsLoaded = false;
        window.__infiItemsCatRefs = null;
        window.__infiItemsValidKeys = null;
        window.__infiItemsExpandedCats = null;
        window.__infiVariationPlatformMap = {};
        window.__infiCurrentLocationId = null;
        window.__infiMenuToLocationMap = {};
        localStorage.removeItem('__infi_last_merchant_payload');
        localStorage.removeItem('__infi_last_menu_payload');
        localStorage.setItem('__infi_last_active_view', 'left');
        const overlay = document.getElementById("infi-merchant-overlay");
        if (overlay) overlay.remove();
    }

    function inspectMerchantIdSwitch(requestUrl) {
        if (!requestUrl) return;
        const match = requestUrl.match(/\/merchants\/([a-zA-Z0-9-]+)/);
        if (match && match[1]) {
            const currentDetectedId = match[1];
            const previousCachedId = localStorage.getItem('__infi_last_detected_merchant_id');
            if (previousCachedId && currentDetectedId !== previousCachedId) wipeMerchantCache();
            localStorage.setItem('__infi_last_detected_merchant_id', currentDetectedId);
        }
    }

    function saveHeadersSnapshot(headersObj) {
        if (!headersObj) return;
        try {
            let savedHeaders = JSON.parse(localStorage.getItem('__infi_merchant_api_headers') || '{}');
            for (const [key, value] of Object.entries(headersObj)) {
                const kLower = key.toLowerCase();
                if (kLower === 'authorization' || kLower.includes('token') || kLower.startsWith('x-')) {
                    savedHeaders[key] = value;
                    window.__infiLiveHeaders[key] = value;
                }
            }
            localStorage.setItem('__infi_merchant_api_headers', JSON.stringify(savedHeaders));
        } catch(e){}
    }

    function buildAuthHeaders() {
        const liveKeys = Object.keys(window.__infiLiveHeaders || {});
        const base = liveKeys.length > 0
            ? { ...window.__infiLiveHeaders }
            : JSON.parse(localStorage.getItem('__infi_merchant_api_headers') || '{}');
        const headers = { "Content-Type": "application/json", ...base };
        const hasAuth = Object.keys(headers).some(k => k.toLowerCase() === 'authorization');
        if (!hasAuth) {
            const token = fetchCurrentAuthToken();
            if (token) headers["Authorization"] = token;
        }
        const appzKey = Object.keys(headers).find(k => k.toLowerCase() === 'x-appz-id');
        if (!appzKey) {
            console.warn("[Infi] buildAuthHeaders: x-appz-id is missing from both live and cached headers. Auth will likely fail.");
        } else {
            console.debug("[Infi] buildAuthHeaders: using x-appz-id =", headers[appzKey], liveKeys.length > 0 ? "(live session)" : "(localStorage cache)");
        }
        return headers;
    }

    function formatApiError(data, sentHeaders) {
        if (!data) return "API Error: empty response";
        const code = data.code || "";
        const msgs = data.messages || {};
        const summary = msgs.summary || data.message || code;
        const details = (msgs.details || []).join(" | ");
        const isAuthError = code === "UNAUTHORIZED" || msgs.type === "AUTH_ERROR";
        if (isAuthError) {
            const appzKey = Object.keys(sentHeaders || {}).find(k => k.toLowerCase() === 'x-appz-id');
            const appzVal = appzKey ? sentHeaders[appzKey] : "(missing!)";
            console.error("[Infi] Auth failed. x-appz-id sent:", appzVal, "| detail:", details);
            return `AUTH FAIL — x-appz-id: ${appzVal} 不存在于当前环境的 authnz.appz 表中。\n详情: ${details || summary}`;
        }
        return `API Error [${code}]: ${summary}${details ? " | " + details : ""}`;
    }

    function handlePassiveMenuIntercept(dataPayload) {
        if (!dataPayload || !dataPayload.menu_id) return;
        window.__infiMenuPayload = dataPayload;
        localStorage.setItem('__infi_last_menu_payload', JSON.stringify(dataPayload));
        localStorage.setItem('__infi_last_active_view', 'right');

        // Resolve and store the location for this menu, then eagerly fetch variation platforms
        const locId = (window.__infiMenuToLocationMap || {})[dataPayload.menu_id] || null;
        if (locId) {
            window.__infiCurrentLocationId = locId;
            fetchVariationPlatforms(locId);
        }

        const rightDropdown = document.getElementById("infim-menu-dropdown");
        if (rightDropdown) rightDropdown.innerHTML = '';
        rightSearchKeyword = "";
        const rSearchInput = document.querySelector('#infim-right-search-control input');
        if (rSearchInput) rSearchInput.value = "";

        if (document.getElementById("infi-merchant-overlay") && document.getElementById("infi-merchant-overlay").style.display !== 'none') {
            if (drawMenuTreeRef) drawMenuTreeRef();
            slideView('right');
        }
    }

    function handleProductsIntercept(payload) {
        window.__infiItemsPayload = payload;
        window.__infiItemsLoaded = true;
        const overlay = document.getElementById("infi-merchant-overlay");
        if (overlay && overlay.style.display !== 'none' && drawItemsTreeRef) {
            window.__infiItemsForceAutoCenter = true;
            drawItemsTreeRef();
        }
    }

    function handleModifierSetsIntercept(payload) {
        const map = {};
        if (Array.isArray(payload)) {
            payload.forEach(ms => { if (ms.modifier_set_id) map[ms.modifier_set_id] = ms.import_type || ''; });
        }
        window.__infiModifierSetsMap = map;
        window.__infiModifierSetsLoaded = true;
    }

    // Processes the location-specific get-products/{locId} response to build a variation_id → platform map
    function handleVariationPlatformIntercept(payload) {
        if (!Array.isArray(payload)) return;
        if (!window.__infiVariationPlatformMap) window.__infiVariationPlatformMap = {};
        payload.forEach(category => {
            if (!category.children || !Array.isArray(category.children)) return;
            category.children.forEach(item => {
                if (!item.children || !Array.isArray(item.children)) return;
                item.children.forEach(variation => {
                    if (variation.catalog_type === 'VARIATION' && variation.platform && variation.key) {
                        window.__infiVariationPlatformMap[variation.key] = variation.platform.toUpperCase();
                    }
                });
            });
        });
        // Redraw the menu tree to reflect newly resolved platform icons
        const overlay = document.getElementById("infi-merchant-overlay");
        if (overlay && overlay.style.display !== 'none' && drawMenuTreeRef) drawMenuTreeRef();
    }

    // Fetch variation platform data for the given location, using cached headers + token
    async function fetchVariationPlatforms(locationId) {
        if (!locationId) return;
        const mId = localStorage.getItem('__infi_last_detected_merchant_id');
        if (!mId) return;
        const host = window.location.origin;
        const finalHeaders = buildAuthHeaders();
        try {
            const res = await originalFetch(`${host}/merchant-portal-api/v1/merchants/${mId}/get-products/${locationId}`, { method: 'GET', headers: finalHeaders });
            const data = await res.json();
            if (data && data.code === "SUCCESS") handleVariationPlatformIntercept(data.payload);
        } catch(e) { /* silently skip, not critical */ }
    }

    const originalFetch = window.fetch;
    window.fetch = function(...args) {
        let requestUrl = '';
        try { requestUrl = typeof args[0] === 'string' ? args[0] : (args[0] && args[0].url) || ''; } catch(e) {}

        return (async () => {
            if (args[1] && args[1].headers) {
                if (args[1].headers instanceof Headers) {
                    let temp = {}; args[1].headers.forEach((v, k) => { temp[k] = v; });
                    saveHeadersSnapshot(temp);
                } else { saveHeadersSnapshot(args[1].headers); }
            }

            if (requestUrl.includes('/merchant-portal-api/')) inspectMerchantIdSwitch(requestUrl);

            const response = await originalFetch.apply(this, args);

            if (requestUrl.includes('/auth/')) wipeMerchantCache();

            if (requestUrl.includes('/location') && requestUrl.endsWith('/menu')) {
                try {
                    const locMatch = requestUrl.match(/\/location\/([a-zA-Z0-9-]+)\/menu/);
                    if (locMatch && locMatch[1]) {
                        const cloneRes = response.clone();
                        cloneRes.json().then(data => { if (data && data.code === "SUCCESS") injectLocationMenus(locMatch[1], data.payload); }).catch(() => {});
                    }
                } catch(e){}
            }

            if (requestUrl.match(/\/merchants\/[a-zA-Z0-9-]+\/menu\/[a-zA-Z0-9-]+(?:\?.*)?$/)) {
                try {
                    const cloneRes = response.clone();
                    cloneRes.json().then(data => { if (data && data.code === "SUCCESS") handlePassiveMenuIntercept(data.payload); }).catch(() => {});
                } catch(e){}
            }
            if (requestUrl.match(/\/merchants\/[a-zA-Z0-9-]+\/get-products/)) {
                try {
                    const locSuffix = requestUrl.match(/\/get-products\/([a-zA-Z0-9-]+)(?:\?.*)?$/);
                    const cloneRes = response.clone();
                    if (locSuffix) {
                        // Location-specific: get-products/{locationId}  →  variation platform map
                        cloneRes.json().then(data => { if (data && data.code === "SUCCESS") handleVariationPlatformIntercept(data.payload); }).catch(() => {});
                    } else {
                        // Merchant-wide: get-products  →  Items Library
                        cloneRes.json().then(data => { if (data && data.code === "SUCCESS") handleProductsIntercept(data.payload); }).catch(() => {});
                    }
                } catch(e){}
            }
            if (requestUrl.match(/\/merchants\/[a-zA-Z0-9-]+\/modifiers-sets/)) {
                try {
                    const cloneRes = response.clone();
                    cloneRes.json().then(data => { if (data && data.code === "SUCCESS") handleModifierSetsIntercept(data.payload); }).catch(() => {});
                } catch(e){}
            }
            return response;
        })();
    };

    const originalXHROpen = XMLHttpRequest.prototype.open;
    const originalXHRSend = XMLHttpRequest.prototype.send;
    const originalXHRSetHeader = XMLHttpRequest.prototype.setRequestHeader;

    XMLHttpRequest.prototype.open = function(method, url) {
        this._requestUrl = url || '';
        if (this._requestUrl.includes('/merchant-portal-api/')) inspectMerchantIdSwitch(this._requestUrl);
        return originalXHROpen.apply(this, arguments);
    };

    XMLHttpRequest.prototype.setRequestHeader = function(header, value) {
        saveHeadersSnapshot({ [header]: value }); return originalXHRSetHeader.apply(this, arguments);
    };

    XMLHttpRequest.prototype.send = function() {
        this.addEventListener('load', function() {
            if (this._requestUrl && this._requestUrl.includes('/auth/')) wipeMerchantCache();
            if (this._requestUrl && this._requestUrl.includes('/location') && this._requestUrl.endsWith('/menu')) {
                try {
                    const locMatch = this._requestUrl.match(/\/location\/([a-zA-Z0-9-]+)\/menu/);
                    const data = JSON.parse(this.responseText);
                    if (locMatch && locMatch[1] && data && data.code === "SUCCESS") injectLocationMenus(locMatch[1], data.payload);
                } catch(e){}
            }
            if (this._requestUrl && this._requestUrl.match(/\/merchants\/[a-zA-Z0-9-]+\/menu\/[a-zA-Z0-9-]+(?:\?.*)?$/)) {
                try {
                    const data = JSON.parse(this.responseText);
                    if (data && data.code === "SUCCESS") handlePassiveMenuIntercept(data.payload);
                } catch(e){}
            }
            if (this._requestUrl && this._requestUrl.match(/\/merchants\/[a-zA-Z0-9-]+\/get-products/)) {
                try {
                    const data = JSON.parse(this.responseText);
                    if (data && data.code === "SUCCESS") {
                        const locSuffix = this._requestUrl.match(/\/get-products\/([a-zA-Z0-9-]+)(?:\?.*)?$/);
                        if (locSuffix) handleVariationPlatformIntercept(data.payload);
                        else           handleProductsIntercept(data.payload);
                    }
                } catch(e){}
            }
            if (this._requestUrl && this._requestUrl.match(/\/merchants\/[a-zA-Z0-9-]+\/modifiers-sets/)) {
                try {
                    const data = JSON.parse(this.responseText);
                    if (data && data.code === "SUCCESS") handleModifierSetsIntercept(data.payload);
                } catch(e){}
            }
        });
        return originalXHRSend.apply(this, arguments);
    };

    function updateMerchantData(merchantRaw, locationsArr) {
        let rawData = merchantRaw.payload ? merchantRaw.payload : merchantRaw;
        let bName = rawData.business_name || rawData.name || merchantRaw.merchant_name || "未命名商户";
        // Fresh refresh — do NOT carry over previously loaded menu sub-nodes.
        // Locations come back from the API without _loadedMenus, so the user sees a clean slate.
        const processedLocations = (locationsArr || []).slice();

        const payload = { merchant_id: rawData.merchant_id || rawData.id || "N/A", merchant_name: bName, raw_merchant: rawData, locations: processedLocations };
        window.__infiMerchantPayload = payload;
        localStorage.setItem('__infi_last_merchant_payload', JSON.stringify(payload));

        const overlay = document.getElementById('infi-merchant-overlay');
        if (overlay && overlay.style.display !== 'none') updateLocationUI(payload);
    }

    function injectLocationMenus(locationId, menusPayload, expandInTree = false) {
        if (!window.__infiMerchantPayload || !window.__infiMerchantPayload.locations) return;
        let found = false;
        window.__infiMerchantPayload.locations = window.__infiMerchantPayload.locations.map(loc => {
            let curId = loc.location_id || loc.id;
            if (curId === locationId) {
                loc._loadedMenus = menusPayload || [];
                loc._hasLoadedMenus = true;
                if (expandInTree) loc._expandedByUser = true;
                found = true;
            }
            return loc;
        });
        // Build menu_id → location_id reverse map so passive menu intercepts can find the location
        if (Array.isArray(menusPayload)) {
            if (!window.__infiMenuToLocationMap) window.__infiMenuToLocationMap = {};
            menusPayload.forEach(m => { if (m.menu_id) window.__infiMenuToLocationMap[m.menu_id] = locationId; });
        }
        if (found) {
            localStorage.setItem('__infi_last_merchant_payload', JSON.stringify(window.__infiMerchantPayload));
            if (drawLocationTreeRef) drawLocationTreeRef();
        }
    }

    async function executeLoadLocationMenus(locationId, textElement) {
        const mId = localStorage.getItem('__infi_last_detected_merchant_id');
        const host = window.location.origin;
        if (!mId) return showToast("暂未捕获到新商户核心ID凭证，请点击 ↻ 重试 ok");

        const el = d3.select(textElement);
        el.text(" Loading...").classed("infim-refresh-loading-active", true);

        const targetUrl = `${host}/merchant-portal-api/v1/merchants/${mId}/location/${locationId}/menu`;
        const finalHeaders = buildAuthHeaders();

        try {
            const res = await originalFetch(targetUrl, { method: 'GET', headers: finalHeaders });
            const data = await res.json();
            if (data && data.code === "SUCCESS") {
                el.classed("infim-refresh-loading-active", false).text(" ✓ 刷新完成 ok").style("fill", "#52c41a");
                setTimeout(() => injectLocationMenus(locationId, data.payload, true), 800);
            } else {
                showToast(formatApiError(data, finalHeaders));
                el.classed("infim-refresh-loading-active", false).text(" Retry").style("fill", "red");
            }
        } catch(e) {
            showToast(`Network Error: ${e.message}`);
            el.classed("infim-refresh-loading-active", false).text(" Error").style("fill", "red");
        }
    }

    async function loadAndSlideToMenuTree(menuId, textElement, locationId) {
        const mId = localStorage.getItem('__infi_last_detected_merchant_id');
        const host = window.location.origin;
        if (!mId) return showToast("暂未捕获到商户ID ok");

        const el = d3.select(textElement);
        el.text("[➜ Loading...]").classed("infim-refresh-loading-active", true);

        const targetUrl = `${host}/merchant-portal-api/v1/merchants/${mId}/menu/${menuId}`;
        const finalHeaders = buildAuthHeaders();

        const modSetsUrl2 = `${host}/merchant-portal-api/v1/merchants/${mId}/modifiers-sets`;
        const varPlatformUrl = locationId ? `${host}/merchant-portal-api/v1/merchants/${mId}/get-products/${locationId}` : null;
        try {
            const fetchPromises = [
                originalFetch(targetUrl, { method: 'GET', headers: finalHeaders }),
                originalFetch(modSetsUrl2, { method: 'GET', headers: finalHeaders }),
            ];
            if (varPlatformUrl) fetchPromises.push(originalFetch(varPlatformUrl, { method: 'GET', headers: finalHeaders }));

            const responses = await Promise.all(fetchPromises);
            const [data, modSetsData, varPlatformData] = await Promise.all(responses.map(r => r.json()));
            if (modSetsData && modSetsData.code === "SUCCESS") handleModifierSetsIntercept(modSetsData.payload);
            if (varPlatformData && varPlatformData.code === "SUCCESS") handleVariationPlatformIntercept(varPlatformData.payload);
            if (data && data.code === "SUCCESS") {
                el.classed("infim-refresh-loading-active", false).text("[➜ Loaded ok]").style("fill", "#52c41a");

                window.__infiMenuPayload = data.payload;
                localStorage.setItem('__infi_last_menu_payload', JSON.stringify(data.payload));

                const rightDropdown = document.getElementById("infim-menu-dropdown");
                if (rightDropdown) rightDropdown.innerHTML = '';
                rightSearchKeyword = "";
                window.__infiForceMenuAutoCenter = true;
                const rSearchInput = document.querySelector('#infim-right-search-control input');
                if (rSearchInput) rSearchInput.value = "";

                setTimeout(() => {
                    el.text("[➜ Load Tree]").style("fill", "#52c41a");
                    slideView('right');
                }, 600);
            } else {
                showToast(formatApiError(data, finalHeaders));
                el.classed("infim-refresh-loading-active", false).text("[Retry]").style("fill", "red");
            }
        } catch(e) {
            showToast(`Network Error: ${e.message}`);
            el.classed("infim-refresh-loading-active", false).text("[Error]").style("fill", "red");
        }
    }

    async function triggerMenuApiRefresh(btnElement) {
        const mId = localStorage.getItem('__infi_last_detected_merchant_id');
        let menuId = "";
        if (window.__infiMenuPayload && window.__infiMenuPayload.menu_id) {
            menuId = window.__infiMenuPayload.menu_id;
        } else {
            const cachedMenu = JSON.parse(localStorage.getItem('__infi_last_menu_payload') || '{}');
            if (cachedMenu.menu_id) menuId = cachedMenu.menu_id;
        }

        if (!mId || !menuId) {
            return showToast("ℹ️ 尚未检测到有效菜单记忆。请先进入 Menu 详情页或在左侧点击 [➜ Load Tree]。");
        }

        const targetUrl = `${window.location.origin}/merchant-portal-api/v1/merchants/${mId}/menu/${menuId}`;

        btnElement.style.transform = "rotate(360deg)";
        btnElement.style.transition = "transform 0.6s ease";

        const finalHeaders = buildAuthHeaders();

        const host2 = window.location.origin;
        const modSetsUrl = `${host2}/merchant-portal-api/v1/merchants/${mId}/modifiers-sets`;
        const locId2 = window.__infiCurrentLocationId;
        const varPlatformUrl2 = locId2 ? `${host2}/merchant-portal-api/v1/merchants/${mId}/get-products/${locId2}` : null;
        try {
            const fetchPromises2 = [
                originalFetch(targetUrl, { method: 'GET', headers: finalHeaders }),
                originalFetch(modSetsUrl, { method: 'GET', headers: finalHeaders }),
            ];
            if (varPlatformUrl2) fetchPromises2.push(originalFetch(varPlatformUrl2, { method: 'GET', headers: finalHeaders }));

            const responses2 = await Promise.all(fetchPromises2);
            const [data, modSetsData, varPlatformData] = await Promise.all(responses2.map(r => r.json()));
            if (modSetsData && modSetsData.code === "SUCCESS") handleModifierSetsIntercept(modSetsData.payload);
            if (varPlatformData && varPlatformData.code === "SUCCESS") handleVariationPlatformIntercept(varPlatformData.payload);
            if (data && data.code === "SUCCESS" && data.payload) {
                window.__infiMenuPayload = data.payload;
                localStorage.setItem('__infi_last_menu_payload', JSON.stringify(data.payload));

                const rightDropdown = document.getElementById("infim-menu-dropdown");
                if (rightDropdown) rightDropdown.innerHTML = '';

                if (drawMenuTreeRef) drawMenuTreeRef();
            } else {
                showToast(formatApiError(data, finalHeaders));
            }
        } catch (e) {
            showToast(`网络异常: ${e.message}`);
        } finally {
            setTimeout(() => {
                btnElement.style.transform = "rotate(0deg)";
                btnElement.style.transition = "none";
            }, 600);
        }
    }

    async function bulkLoadAllLocationMenus(btnElement) {
        const mId = localStorage.getItem('__infi_last_detected_merchant_id');
        const host = window.location.origin;
        if (!mId) { showToast("暂未捕获到商户ID，请点击 ↻ 重试 ok"); return; }

        const locs = (window.__infiMerchantPayload && window.__infiMerchantPayload.locations) || [];
        if (locs.length === 0) { showToast("暂无门店数据，请先点击 ↻ 刷新 ok"); return; }

        // Locations that haven't been loaded yet
        const unloadedLocs = locs.filter(loc => !loc._hasLoadedMenus);
        if (unloadedLocs.length === 0) {
            // All cached — just redraw
            if (drawLocationTreeRef) drawLocationTreeRef();
            return;
        }

        if (btnElement) { btnElement.style.transform = "rotate(360deg)"; btnElement.style.transition = "transform 0.6s ease"; }

        const finalHeaders = buildAuthHeaders();

        // Fetch all unloaded locations in parallel
        const results = await Promise.all(unloadedLocs.map(async loc => {
            const locId = loc.location_id || loc.id;
            try {
                const res = await originalFetch(`${host}/merchant-portal-api/v1/merchants/${mId}/location/${locId}/menu`, { method: 'GET', headers: finalHeaders });
                const data = await res.json();
                return { locId, payload: (data && data.code === "SUCCESS") ? (data.payload || []) : null };
            } catch(e) {
                return { locId, payload: null };
            }
        }));

        // Apply all results at once without intermediate redraws
        if (window.__infiMerchantPayload && window.__infiMerchantPayload.locations) {
            const resultMap = new Map(results.filter(r => r.payload !== null).map(r => [r.locId, r.payload]));
            window.__infiMerchantPayload.locations = window.__infiMerchantPayload.locations.map(loc => {
                const locId = loc.location_id || loc.id;
                if (resultMap.has(locId)) {
                    loc._loadedMenus = resultMap.get(locId);
                    loc._hasLoadedMenus = true;
                }
                return loc;
            });
            localStorage.setItem('__infi_last_merchant_payload', JSON.stringify(window.__infiMerchantPayload));
        }

        if (drawLocationTreeRef) drawLocationTreeRef();
        if (btnElement) setTimeout(() => { btnElement.style.transform = "rotate(0deg)"; btnElement.style.transition = "none"; }, 700);
    }

    async function executeActiveSnoopRequest(btnElement = null) {
        const mId = localStorage.getItem('__infi_last_detected_merchant_id');
        const host = window.location.origin;
        if (!mId) return showToast("ℹ 暂未激活可用商户网络前缀，请点击网页内任一选项即可自动识别！");

        if (btnElement) { btnElement.style.transform = "rotate(360deg)"; btnElement.style.transition = "transform 0.6s ease"; }

        const mainUrl = `${host}/merchant-portal-api/v1/merchants/${mId}`;
        const locUrl = `${host}/merchant-portal-api/v1/merchants/${mId}/locations`;
        const finalHeaders = buildAuthHeaders();

        try {
            const [resMain, resLoc] = await Promise.all([ originalFetch(mainUrl, { method: 'GET', headers: finalHeaders }), originalFetch(locUrl, { method: 'GET', headers: finalHeaders }) ]);
            const dataMain = await resMain.json();
            const dataLoc = await resLoc.json();

            if (dataMain && dataLoc && dataMain.code === "SUCCESS" && dataLoc.code === "SUCCESS") {
                updateMerchantData(dataMain, dataLoc.payload || dataLoc.data || []);
            } else { showToast(formatApiError(dataMain.code !== "SUCCESS" ? dataMain : dataLoc, finalHeaders)); }
        } catch (e) { showToast(`Network Error: ${e.message}`); } finally {
            if (btnElement) setTimeout(() => { btnElement.style.transform = "rotate(0deg)"; btnElement.style.transition = "none"; }, 600);
        }
    }

    function safeCheckMatch(keyword, targetStr, isRegex, isCaseS) {
        if (!keyword || targetStr == null) return false;
        let s = String(targetStr);
        let needle = isCaseS ? keyword : keyword.toLowerCase();
        let haystack = isCaseS ? s : s.toLowerCase();

        if (isRegex) {
            try {
                if (new RegExp(keyword, isCaseS ? "" : "i").test(s)) return true;
            } catch(e) {}
            return haystack.includes(needle);
        }
        // Exact match mode (.* button off): supports | for multiple exact conditions (OR)
        return needle.split('|').some(seg => { const t = seg.trim(); return t.length > 0 && haystack === t; });
    }

    // Returns a display string like "$1.50", or null if no price found.
    // Assumes price_money.amount / price fields are stored in cents (integer).
    function getNodePrice(raw, typeUpper) {
        if (!raw) return null;
        let cents = null;
        if (typeUpper === 'COMBOSET') {
            if (raw.group_price != null) {
                const n = Number(raw.group_price);
                if (!isNaN(n)) cents = n;
            }
        } else {
            let v = null;
            if (raw.price_money && raw.price_money.amount != null) v = raw.price_money.amount;
            else if (raw.base_price_money && raw.base_price_money.amount != null) v = raw.base_price_money.amount;
            else if (raw.price != null) v = raw.price;
            if (v != null) {
                // If already a formatted price string (e.g. "$1.5-$2.5"), display as-is
                if (typeof v === 'string' && /^\$/.test(v.trim())) return v.trim();
                const n = Number(v);
                if (!isNaN(n)) cents = n;
            }
        }
        if (cents === null) return null;
        const dollars = cents ;
        return `$${dollars % 1 === 0 ? dollars : dollars.toFixed(2)}`;
    }

    function getPlatformIconUrl(platform) {
        if (!platform) return null;
        const p = platform.toUpperCase();
        if (p === 'SQUARE') return '/merchant-portal/assets/img/square_logo.svg';
        if (p === 'HUNGERRUSH') return '/merchant-portal/assets/img/hungerrush_logo.svg';
        if (p === 'TOAST') return '/merchant-portal/assets/img/toast_logo.svg';
        if (p === 'LIGHTSPEED') return '/merchant-portal/assets/img/lightspeed_logo.svg';
        return null;
    }

    function transformLocationData(payload, validLocIds, keyword) {
        let root = { type: 'Merchant', name: payload.merchant_name, id: payload.merchant_id, children: [], raw: payload.raw_merchant };
        if (payload.locations && Array.isArray(payload.locations)) {
            payload.locations.forEach(loc => {
                let locId = loc.location_id || loc.id;
                if (!validLocIds.has(locId)) return;
                let locName = loc.name || loc.title || "未命名门店";
                let locMatchedSelf = safeCheckMatch(keyword, locName, isLeftRegexMode, isLeftCaseSensitive) || safeCheckMatch(keyword, locId, isLeftRegexMode, isLeftCaseSensitive);
                let locNode = { type: 'Location', name: locName, id: locId, children: [], raw: loc };
                let anyMenuHit = false;
                // Show menu sub-nodes when: global "细节" toggle is ON, user manually loaded this location, or keyword is active
                if ((window.__infiShowLocationMenus || loc._expandedByUser || keyword) && loc._loadedMenus && Array.isArray(loc._loadedMenus)) {
                    loc._loadedMenus.forEach(menu => {
                        let mName = menu.menu_name || "未命名菜单";
                        let menuMatched = safeCheckMatch(keyword, mName, isLeftRegexMode, isLeftCaseSensitive) || safeCheckMatch(keyword, menu.menu_id, isLeftRegexMode, isLeftCaseSensitive);
                        if (!keyword || menuMatched || locMatchedSelf) {
                            locNode.children.push({ type: 'Menu', name: mName, id: menu.menu_id, raw: menu });
                            if (menuMatched) anyMenuHit = true;
                        }
                    });
                }
                if (!keyword || locMatchedSelf || anyMenuHit) {
                    if (locNode.children.length === 0) delete locNode.children;
                    root.children.push(locNode);
                }
            });
        }
        return root;
    }

    function transformMenuDataForD3(payload, validGroupIds, validItemIds, showSubItems, keyword) {
        function attachSubItemDetails(targetNode, item, itemMatchedSelf, groupMatchedSelf) {
            let anySubHit = false;
            let matchedVars = [];
            let varNodeMap = new Map();

            if (item.variations && Array.isArray(item.variations)) {
                item.variations.forEach(v => {
                    let vHit = safeCheckMatch(keyword, v.name, isRightRegexMode, isRightCaseSensitive) || safeCheckMatch(keyword, v.id, isRightRegexMode, isRightCaseSensitive);
                    if (!keyword || vHit || itemMatchedSelf || groupMatchedSelf) {
                        const varPlatform = ((window.__infiVariationPlatformMap || {})[v.id] || '').toUpperCase();
                        let varNode = { type: 'Var', name: v.name, id: v.id, children: [], raw: { ...v, platform: varPlatform } };
                        matchedVars.push(varNode);
                        varNodeMap.set(String(v.id), varNode);
                        if (vHit) anySubHit = true;
                    }
                });
            }

            let itemLevelSets = [];
            if (item.modifier_set && Array.isArray(item.modifier_set)) {
                item.modifier_set.forEach(ms => {
                    let msHit = safeCheckMatch(keyword, ms.name, isRightRegexMode, isRightCaseSensitive) || safeCheckMatch(keyword, ms.modifier_set_id, isRightRegexMode, isRightCaseSensitive);
                    const msPlatform = ((window.__infiModifierSetsMap || {})[ms.modifier_set_id] || '').toUpperCase();
                    let msNode = { type: 'Set', name: ms.name, id: ms.modifier_set_id, children: [], raw: { ...ms, platform: msPlatform || ms.platform || '' } };

                    if (ms.modifiers && Array.isArray(ms.modifiers)) {
                        ms.modifiers.forEach(m => {
                            let mHit = safeCheckMatch(keyword, m.name, isRightRegexMode, isRightCaseSensitive) || safeCheckMatch(keyword, m.modifier_id, isRightRegexMode, isRightCaseSensitive);
                            if (!keyword || mHit || msHit || itemMatchedSelf || groupMatchedSelf) {
                                msNode.children.push({ type: 'Mod', name: m.name, id: m.modifier_id, raw: m });
                                if (mHit) anySubHit = true;
                            }
                        });
                    }
                    if (msHit) anySubHit = true;

                    let hasValidLinkage = false;
                    if (ms.variation_ids && Array.isArray(ms.variation_ids) && ms.variation_ids.length > 0) {
                        ms.variation_ids.forEach(vid => {
                            let targetVarNode = varNodeMap.get(String(vid));
                            if (targetVarNode) { targetVarNode.children.push(msNode); hasValidLinkage = true; }
                        });
                    }

                    if (!hasValidLinkage) {
                        if (!keyword || msHit || msNode.children.length > 0 || itemMatchedSelf || groupMatchedSelf) {
                            itemLevelSets.push(msNode);
                        }
                    }
                });
            }

            if (matchedVars.length > 0) {
                // If every variation has the same non-empty platform, surface it on the group node
                const varPlatforms = matchedVars.map(n => n.raw && n.raw.platform).filter(Boolean);
                const allSamePlatform = varPlatforms.length === matchedVars.length && varPlatforms.every(p => p === varPlatforms[0]);
                const groupPlatform = allSamePlatform ? varPlatforms[0] : '';
                targetNode.children.push({ type: 'Type', name: "Variations", id: "N/A", children: matchedVars, raw: groupPlatform ? { platform: groupPlatform } : {} });
            }
            if (itemLevelSets.length > 0) targetNode.children.push({ type: 'Type', name: "Modifier Sets", id: "N/A", children: itemLevelSets });

            return anySubHit;
        }

        let root = { type: 'Menu', name: `${payload.menu_name || 'Unnamed Menu'}`, id: payload.menu_id, children: [], raw: payload };
        if (!payload.group || !Array.isArray(payload.group)) return root;

        payload.group.forEach(g => {
            if (!validGroupIds.has(g.group_id)) return;

            let groupMatchedSelf = safeCheckMatch(keyword, g.name, isRightRegexMode, isRightCaseSensitive) || safeCheckMatch(keyword, g.group_id, isRightRegexMode, isRightCaseSensitive);
            let groupNode = { type: 'Group', name: g.name, id: g.group_id, children: [], raw: g };

            if (g.item_or_combo && Array.isArray(g.item_or_combo)) {
                g.item_or_combo.forEach(item => {
                    if (!validItemIds.has(item.id)) return;

                    let itemMatchedSelf = safeCheckMatch(keyword, item.name, isRightRegexMode, isRightCaseSensitive) || safeCheckMatch(keyword, item.id, isRightRegexMode, isRightCaseSensitive);
                    let dynamicType = item.type ? String(item.type) : 'Item';
                    let itemNode = { type: dynamicType, name: item.name, id: item.id, children: [], raw: item };

                    let anySubItemHit = false;

                    if (showSubItems) {
                        if (dynamicType.toUpperCase() === 'COMBO' && item.combo_sets && Array.isArray(item.combo_sets)) {
                            let comboSetsParent = { type: 'Type', name: "Combo Sets", id: "N/A", children: [] };

                            item.combo_sets.forEach(cs => {
                                let csName = cs.title || "未命名套餐组";
                                let csId = cs.id || "N/A";
                                let csHit = safeCheckMatch(keyword, csName, isRightRegexMode, isRightCaseSensitive) || safeCheckMatch(keyword, csId, isRightRegexMode, isRightCaseSensitive);

                                let csNode = { type: 'ComboSet', name: csName, id: csId, children: [], raw: cs };
                                let anyComboItemHit = false;

                                if (cs.items && Array.isArray(cs.items)) {
                                    cs.items.forEach(cItem => {
                                        let cItemName = cItem.title || "未命名单品";
                                        let cItemId = cItem.id || "N/A";
                                        let cItemHit = safeCheckMatch(keyword, cItemName, isRightRegexMode, isRightCaseSensitive) || safeCheckMatch(keyword, cItemId, isRightRegexMode, isRightCaseSensitive);

                                        let cItemNode = { type: 'Item', name: cItemName, id: cItemId, children: [], raw: cItem };

                                        let innerHit = attachSubItemDetails(cItemNode, cItem, cItemHit || csHit || itemMatchedSelf, groupMatchedSelf);
                                        if (cItemHit || innerHit) anyComboItemHit = true;

                                        if (!keyword || cItemHit || innerHit || csHit || itemMatchedSelf || groupMatchedSelf) {
                                            csNode.children.push(cItemNode);
                                        }
                                    });
                                }

                                if (csHit || anyComboItemHit) anySubItemHit = true;
                                if (!keyword || csHit || anyComboItemHit || itemMatchedSelf || groupMatchedSelf) {
                                    comboSetsParent.children.push(csNode);
                                }
                            });

                            if (comboSetsParent.children.length > 0) itemNode.children.push(comboSetsParent);
                        } else {
                            anySubItemHit = attachSubItemDetails(itemNode, item, itemMatchedSelf, groupMatchedSelf);
                        }
                    }

                    if (!keyword || itemMatchedSelf || anySubItemHit || groupMatchedSelf) {
                        groupNode.children.push(itemNode);
                    }
                });
            }

            if (!keyword || groupMatchedSelf || groupNode.children.length > 0) {
                root.children.push(groupNode);
            }
        });

        return root;
    }

    function slideView(direction) {
        const slider = document.getElementById('infi-slider-wrapper');
        if (!slider) return;
        if (direction === 'right') {
            slider.style.transform = 'translateX(-100vw)';
            localStorage.setItem('__infi_last_active_view', 'right');
            if (drawMenuTreeRef) drawMenuTreeRef();
        } else if (direction === 'items') {
            slider.style.transform = 'translateX(-200vw)';
            localStorage.setItem('__infi_last_active_view', 'items');
            if (!window.__infiItemsLoaded) {
                fetchItemsLibraryData(null);
            } else if (drawItemsTreeRef) {
                drawItemsTreeRef();
            }
        } else {
            slider.style.transform = 'translateX(0)';
            localStorage.setItem('__infi_last_active_view', 'left');
            if (drawLocationTreeRef) drawLocationTreeRef();
        }
    }

    function buildDualViewUI() {
        if (document.getElementById("infi-merchant-overlay")) return;

        const styleSheet = document.createElement("style");
        styleSheet.innerText = `
            .infim-prop-val-cell { cursor: pointer; transition: color 0.15s; position: relative; }
            .infim-prop-val-cell:hover { color: #52c41a !important; text-decoration: underline; }
            .infim-search-toggle-btn {
                width: 24px; height: 24px; line-height: 22px; text-align: center;
                border-radius: 4px; font-size: 11px; font-family: monospace; font-weight: bold;
                cursor: pointer; user-select: none; border: 1px solid #ccc; background: #fff; color: #555;
                transition: all 0.15s ease;
            }
            .infim-search-toggle-btn.active { background: #52c41a !important; color: #fff !important; border-color: #52c41a !important; }

            .infim-detail-toggle-btn {
                padding: 3px 8px; height: 24px; line-height: 18px; text-align: center;
                border-radius: 4px; font-size: 12px; font-weight: bold; font-family: sans-serif;
                cursor: pointer; user-select: none; border: 1px solid #ccc; background: #fff; color: #555;
                transition: all 0.15s ease; flex-shrink: 0;
            }
            .infim-detail-toggle-btn.active { background: #52c41a !important; color: #fff !important; border-color: #52c41a !important; }

            .infim-refresh-btn {
                width: 24px; height: 24px; line-height: 22px; text-align: center;
                border-radius: 4px; font-size: 14px; font-weight: bold; cursor: pointer;
                user-select: none; border: 1px solid #ccc; background: #fff; color: #52c41a;
                display: flex; align-items: center; justify-content: center; outline: none; box-sizing: border-box;
            }
            .infim-refresh-btn:hover { background: #f6ffed; border-color: #52c41a; }

            .infim-clear-badge-btn {
                position: absolute; right: 6px; top: 50%; transform: translateY(-50%);
                padding: 2px 8px; background: #e8e8e8; color: #52c41a; font-weight: bold;
                font-size: 11px; border-radius: 12px; cursor: pointer; user-select: none; display: none; align-items: center; gap: 4px; border: 1px solid transparent; transition: all 0.2s ease;
            }
            .infim-clear-badge-btn:hover { background: #52c41a; color: #fff; border-color: #52c41a; }

            .infim-tree-name-clickable { cursor: pointer; }
            .infim-tree-name-clickable:hover .infim-tspan-name { color: #52c41a !important; text-decoration: underline; }

            input[type="checkbox"] { accent-color: #52c41a !important; }

            #infim-tooltip-panel::-webkit-scrollbar { width: 4px !important; }
            #infim-tooltip-panel::-webkit-scrollbar-track { background: transparent !important; }
            #infim-tooltip-panel::-webkit-scrollbar-thumb { background: rgba(0, 0, 0, 0.15) !important; border-radius: 2px !important; }
            #infim-tooltip-panel::-webkit-scrollbar-thumb:hover { background: rgba(82, 196, 26, 0.5) !important; }

            .infim-btn-action { font-size: 13px !important; fill: #9ca3af !important; font-weight: 800 !important; cursor: pointer !important; transition: fill 0.2s ease-in-out; }
            .infim-btn-action:hover { fill: #52c41a !important; }

            .infim-refresh-loading-active { fill: #ff0055 !important; animation: infimPulseAni 0.7s infinite alternate ease-in-out !important; }
            @keyframes infimPulseAni { 0% { opacity: 0.3; } 100% { opacity: 1; } }

            #infi-slider-wrapper { display: flex; width: 300vw; height: 100vh; transition: transform 0.5s cubic-bezier(0.25, 0.8, 0.25, 1); }
            .infi-view-panel { width: 100vw; height: 100vh; flex-shrink: 0; position: relative; overflow: hidden; background-color:rgba(248, 249, 250, 0.85); }

            .infi-nav-btn {
                position: absolute; top: 50%; transform: translateY(-50%); width: 40px; height: 120px;
                background: rgba(0,0,0,0.06); color: #888; display: flex; align-items: center; justify-content: center;
                font-size: 24px; cursor: pointer; z-index: 999990; border-radius: 6px; border: 1px solid rgba(0,0,0,0.05);
                transition: all 0.2s; font-weight: bold; font-family: monospace;
            }
            .infi-nav-btn:hover { background: #52c41a; color: white; border-color: #52c41a; box-shadow: 0 4px 15px rgba(82,196,26,0.3); }
            #infi-nav-right { right: 20px; }
            #infi-nav-right2 { right: 20px; }
            #infi-nav-left { left: 20px; }
            #infi-nav-left2 { left: 20px; }

            .infi-view-title { position:absolute; bottom: 20px; left: 20px; font-size: 24px; font-weight: 900; color: rgba(0,0,0,0.1); user-select: none; pointer-events: none; }
        `;
        document.head.appendChild(styleSheet);

        const overlay = document.createElement('div');
        overlay.id = "infi-merchant-overlay";
        overlay.style = "position:fixed; top:0; left:0; width:100vw; height:100vh; z-index:999998; overflow:hidden;";

        const sliderWrapper = document.createElement('div');
        sliderWrapper.id = "infi-slider-wrapper";

        const leftView = document.createElement('div');
        leftView.className = "infi-view-panel"; leftView.id = "infi-left-view";
        const rightNavBtn = document.createElement('div'); rightNavBtn.className = "infi-nav-btn"; rightNavBtn.id = "infi-nav-right"; rightNavBtn.innerHTML = "〉";
        rightNavBtn.onclick = () => slideView('right');
        leftView.appendChild(rightNavBtn);
        const leftTitle = document.createElement('div'); leftTitle.className = "infi-view-title"; leftTitle.innerText = "MERCHANT LOCATION TREE"; leftView.appendChild(leftTitle);

        const rightView = document.createElement('div');
        rightView.className = "infi-view-panel"; rightView.id = "infi-right-view";
        const leftNavBtn = document.createElement('div'); leftNavBtn.className = "infi-nav-btn"; leftNavBtn.id = "infi-nav-left"; leftNavBtn.innerHTML = "〈";
        leftNavBtn.onclick = () => slideView('left');
        rightView.appendChild(leftNavBtn);
        const rightToItemsNavBtn = document.createElement('div'); rightToItemsNavBtn.className = "infi-nav-btn"; rightToItemsNavBtn.id = "infi-nav-right2"; rightToItemsNavBtn.innerHTML = "〉";
        rightToItemsNavBtn.onclick = () => slideView('items');
        rightView.appendChild(rightToItemsNavBtn);
        const rightTitle = document.createElement('div'); rightTitle.className = "infi-view-title"; rightTitle.innerText = "MENU DETAIL TREE"; rightView.appendChild(rightTitle);

        const itemsView = document.createElement('div');
        itemsView.className = "infi-view-panel"; itemsView.id = "infi-items-view";
        const itemsLeftNavBtn = document.createElement('div'); itemsLeftNavBtn.className = "infi-nav-btn"; itemsLeftNavBtn.id = "infi-nav-left2"; itemsLeftNavBtn.innerHTML = "〈";
        itemsLeftNavBtn.onclick = () => slideView('right');
        itemsView.appendChild(itemsLeftNavBtn);
        const itemsTitle = document.createElement('div'); itemsTitle.className = "infi-view-title"; itemsTitle.innerText = "ITEMS LIBRARY TREE"; itemsView.appendChild(itemsTitle);

        sliderWrapper.appendChild(leftView); sliderWrapper.appendChild(rightView); sliderWrapper.appendChild(itemsView); overlay.appendChild(sliderWrapper);

        const tooltipPanel = document.createElement('div');
        tooltipPanel.id = "infim-tooltip-panel";
        tooltipPanel.style = `position: fixed; top: 60px; right: 10px; width: 320px; max-height: 85vh; background: rgba(255, 255, 255, 0.9); border: 1px solid rgba(0, 0, 0, 0.05); box-shadow: -4px 4px 15px rgba(0, 0, 0, 0.08); border-radius: 6px; padding: 5px 10px; font-family: system-ui, -apple-system, sans-serif; font-size: 11px; line-height: 1.5; color: #111; overflow-y: auto; z-index: 999999; display: none; pointer-events: none;`;
        overlay.appendChild(tooltipPanel);

        const leftControl = document.createElement('div');
        leftControl.id = "infim-left-search-control";
        leftControl.style = "position:absolute; top:20px; left:50%; transform:translateX(-50%); background:#fff; border-radius:12px; box-shadow:0 8px 30px rgba(0,0,0,0.15); border:1px solid #eee; z-index:999999; display:flex; flex-direction:column; width:520px; max-height:65vh; overflow:hidden; font-family:sans-serif; transition: max-height 0.25s ease;";
        leftControl.addEventListener('click', (e) => { e.stopPropagation(); });

        const lActionRow = document.createElement('div'); lActionRow.style = "display:flex; justify-content:flex-start; align-items:center; padding:12px; border-bottom:1px solid #eee; background:#fcfcfc; gap:8px; box-sizing:border-box;";
        const lToggleAllBtn = document.createElement('button'); lToggleAllBtn.innerText = "全选/反选"; lToggleAllBtn.style = "background:transparent; border:none; color:#52c41a; cursor:pointer; font-weight:bold; font-size:13px; padding:0; flex-shrink:0; outline:none;";
        const lSearchWrapper = document.createElement('div'); lSearchWrapper.style = "position:relative; flex:1; display:flex; align-items:center; gap:6px;";
        const lSearchInput = document.createElement('input'); lSearchInput.type = 'text'; lSearchInput.placeholder = '输入字符模糊过滤门店/菜单...'; lSearchInput.style = "flex:1; padding:7px 65px 7px 10px; border:1px solid #ccc; border-radius:6px; outline:none; font-size:13px; box-sizing:border-box; transition: border-color 0.15s;";
        const lClearBadgeBtn = document.createElement('div'); lClearBadgeBtn.className = "infim-clear-badge-btn";
        const lInnerInputContainer = document.createElement('div'); lInnerInputContainer.style = "position:relative; flex:1; display:flex; align-items:center;";
        lInnerInputContainer.appendChild(lSearchInput); lInnerInputContainer.appendChild(lClearBadgeBtn);
        const lRegexBtn = document.createElement('div'); lRegexBtn.className = isLeftRegexMode ? "infim-search-toggle-btn active" : "infim-search-toggle-btn"; lRegexBtn.innerText = ".*";
        const lCaseBtn = document.createElement('div'); lCaseBtn.className = "infim-search-toggle-btn"; lCaseBtn.innerText = "Aa";
        const lDetailToggleBtn = document.createElement('div');
        lDetailToggleBtn.className = window.__infiShowLocationMenus ? "infim-detail-toggle-btn active" : "infim-detail-toggle-btn";
        lDetailToggleBtn.id = "infim-loc-detail-btn";
        lDetailToggleBtn.innerText = "细节";
        lDetailToggleBtn.title = "加载并展示所有门店下的 Menu 子节点";
        const lRefreshBtn = document.createElement('div'); lRefreshBtn.className = "infim-refresh-btn"; lRefreshBtn.innerHTML = "↻";
        lRefreshBtn.onclick = function(e) { e.stopPropagation(); executeActiveSnoopRequest(this); };

        lSearchWrapper.appendChild(lInnerInputContainer); lSearchWrapper.appendChild(lRegexBtn); lSearchWrapper.appendChild(lCaseBtn); lSearchWrapper.appendChild(lDetailToggleBtn); lSearchWrapper.appendChild(lRefreshBtn);
        lActionRow.appendChild(lToggleAllBtn); lActionRow.appendChild(lSearchWrapper); leftControl.appendChild(lActionRow);

        const lTreeBodyContainer = document.createElement('div'); lTreeBodyContainer.style = "display:none; flex-direction:column; flex:1; overflow:hidden;";
        const lGroupDropdown = document.createElement('div'); lGroupDropdown.id = "infim-loc-dropdown"; lGroupDropdown.style = "flex:1; overflow-y:auto; overflow-x:hidden; padding:8px 0; background:#fff; max-height:400px;";
        lTreeBodyContainer.appendChild(lGroupDropdown); leftControl.appendChild(lTreeBodyContainer);
        leftView.appendChild(leftControl);

        const rightControl = document.createElement('div');
        rightControl.id = "infim-right-search-control";
        rightControl.style = "position:absolute; top:20px; left:50%; transform:translateX(-50%); background:#fff; border-radius:12px; box-shadow:0 8px 30px rgba(0,0,0,0.15); border:1px solid #eee; z-index:999999; display:flex; flex-direction:column; width:520px; max-height:65vh; overflow:hidden; font-family:sans-serif; transition: max-height 0.25s ease;";
        rightControl.addEventListener('click', (e) => { e.stopPropagation(); });

        const rActionRow = document.createElement('div'); rActionRow.style = "display:flex; justify-content:flex-start; align-items:center; padding:12px; border-bottom:1px solid #eee; background:#fcfcfc; gap:8px; box-sizing:border-box;";
        const rToggleAllBtn = document.createElement('button'); rToggleAllBtn.innerText = "全选/反选"; rToggleAllBtn.style = "background:transparent; border:none; color:#52c41a; cursor:pointer; font-weight:bold; font-size:13px; padding:0; flex-shrink:0; outline:none;";
        const rSearchWrapper = document.createElement('div'); rSearchWrapper.style = "position:relative; flex:1; display:flex; align-items:center; gap:6px;";
        const rSearchInput = document.createElement('input'); rSearchInput.type = 'text'; rSearchInput.placeholder = '输入字符模糊过滤Item/Combo...'; rSearchInput.style = "flex:1; padding:7px 65px 7px 10px; border:1px solid #ccc; border-radius:6px; outline:none; font-size:13px; box-sizing:border-box; transition: border-color 0.15s;";
        const rClearBadgeBtn = document.createElement('div'); rClearBadgeBtn.className = "infim-clear-badge-btn";
        const rInnerInputContainer = document.createElement('div'); rInnerInputContainer.style = "position:relative; flex:1; display:flex; align-items:center;";
        rInnerInputContainer.appendChild(rSearchInput); rInnerInputContainer.appendChild(rClearBadgeBtn);
        const rRegexBtn = document.createElement('div'); rRegexBtn.className = isRightRegexMode ? "infim-search-toggle-btn active" : "infim-search-toggle-btn"; rRegexBtn.innerText = ".*";
        const rCaseBtn = document.createElement('div'); rCaseBtn.className = "infim-search-toggle-btn"; rCaseBtn.innerText = "Aa";
        const rDetailToggleBtn = document.createElement('div'); rDetailToggleBtn.className = window.__infiShowSubItems ? "infim-detail-toggle-btn active" : "infim-detail-toggle-btn"; rDetailToggleBtn.innerText = "细节";

        const rRefreshBtn = document.createElement('div'); rRefreshBtn.className = "infim-refresh-btn"; rRefreshBtn.innerHTML = "↻";
        rRefreshBtn.title = "依托持久化记忆，跨越同步重载 Menu 数据";
        rRefreshBtn.onclick = function(e) { e.stopPropagation(); triggerMenuApiRefresh(this); };

        rSearchWrapper.appendChild(rInnerInputContainer); rSearchWrapper.appendChild(rRegexBtn); rSearchWrapper.appendChild(rCaseBtn); rSearchWrapper.appendChild(rDetailToggleBtn); rSearchWrapper.appendChild(rRefreshBtn);
        rActionRow.appendChild(rToggleAllBtn); rActionRow.appendChild(rSearchWrapper); rightControl.appendChild(rActionRow);

        const rTreeBodyContainer = document.createElement('div'); rTreeBodyContainer.style = "display:none; flex-direction:column; flex:1; overflow:hidden;";
        const rGroupDropdown = document.createElement('div'); rGroupDropdown.id = "infim-menu-dropdown"; rGroupDropdown.style = "flex:1; overflow-y:auto; overflow-x:hidden; padding:8px 0; background:#fff; max-height:400px;";
        rTreeBodyContainer.appendChild(rGroupDropdown); rightControl.appendChild(rTreeBodyContainer);
        rightView.appendChild(rightControl);

        // ── Items Library control bar ──────────────────────────────────────
        const itemsControl = document.createElement('div');
        itemsControl.id = "infim-items-search-control";
        itemsControl.style = "position:absolute; top:20px; left:50%; transform:translateX(-50%); background:#fff; border-radius:12px; box-shadow:0 8px 30px rgba(0,0,0,0.15); border:1px solid #eee; z-index:999999; display:flex; flex-direction:column; width:520px; max-height:65vh; overflow:hidden; font-family:sans-serif; transition: max-height 0.25s ease;";
        itemsControl.addEventListener('click', (e) => { e.stopPropagation(); });

        const iActionRow = document.createElement('div'); iActionRow.style = "display:flex; justify-content:flex-start; align-items:center; padding:12px; border-bottom:1px solid #eee; background:#fcfcfc; gap:8px; box-sizing:border-box;";
        const iToggleAllBtn = document.createElement('button'); iToggleAllBtn.innerText = "全选/反选"; iToggleAllBtn.style = "background:transparent; border:none; color:#52c41a; cursor:pointer; font-weight:bold; font-size:13px; padding:0; flex-shrink:0; outline:none;";
        const iSearchWrapper = document.createElement('div'); iSearchWrapper.style = "position:relative; flex:1; display:flex; align-items:center; gap:6px;";
        const iSearchInput = document.createElement('input'); iSearchInput.type = 'text'; iSearchInput.placeholder = '输入字符模糊过滤 Item/Category...'; iSearchInput.style = "flex:1; padding:7px 65px 7px 10px; border:1px solid #ccc; border-radius:6px; outline:none; font-size:13px; box-sizing:border-box; transition: border-color 0.15s;";
        const iClearBadgeBtn = document.createElement('div'); iClearBadgeBtn.className = "infim-clear-badge-btn";
        const iInnerInputContainer = document.createElement('div'); iInnerInputContainer.style = "position:relative; flex:1; display:flex; align-items:center;";
        iInnerInputContainer.appendChild(iSearchInput); iInnerInputContainer.appendChild(iClearBadgeBtn);
        const iRegexBtn = document.createElement('div'); iRegexBtn.className = isItemsRegexMode ? "infim-search-toggle-btn active" : "infim-search-toggle-btn"; iRegexBtn.innerText = ".*";
        const iCaseBtn = document.createElement('div'); iCaseBtn.className = "infim-search-toggle-btn"; iCaseBtn.innerText = "Aa";
        const iDetailToggleBtn = document.createElement('div'); iDetailToggleBtn.className = window.__infiShowItemsSubItems ? "infim-detail-toggle-btn active" : "infim-detail-toggle-btn"; iDetailToggleBtn.innerText = "细节";
        const iRefreshBtn = document.createElement('div'); iRefreshBtn.className = "infim-refresh-btn"; iRefreshBtn.innerHTML = "↻";
        iRefreshBtn.title = "重新请求 Items Library 数据";
        iRefreshBtn.onclick = function(e) { e.stopPropagation(); fetchItemsLibraryData(this); };

        iSearchWrapper.appendChild(iInnerInputContainer); iSearchWrapper.appendChild(iRegexBtn); iSearchWrapper.appendChild(iCaseBtn); iSearchWrapper.appendChild(iDetailToggleBtn); iSearchWrapper.appendChild(iRefreshBtn);
        iActionRow.appendChild(iToggleAllBtn); iActionRow.appendChild(iSearchWrapper); itemsControl.appendChild(iActionRow);

        const iTreeBodyContainer = document.createElement('div'); iTreeBodyContainer.style = "display:none; flex-direction:column; flex:1; overflow:hidden;";
        const iCategoryDropdown = document.createElement('div'); iCategoryDropdown.id = "infim-items-dropdown"; iCategoryDropdown.style = "flex:1; overflow-y:auto; overflow-x:hidden; padding:8px 0; background:#fff; max-height:400px;";
        iTreeBodyContainer.appendChild(iCategoryDropdown); itemsControl.appendChild(iTreeBodyContainer);
        itemsView.appendChild(itemsControl);

        document.body.appendChild(overlay);

        d3.select(leftView).append("svg").attr("id", "infim-svg-left").style("width", "100vw").style("height", "100vh").style("cursor", "grab").style("display", "block").append("g");
        d3.select(rightView).append("svg").attr("id", "infim-svg-right").style("width", "100vw").style("height", "100vh").style("cursor", "grab").style("display", "block").append("g");
        d3.select(itemsView).append("svg").attr("id", "infim-svg-items").style("width", "100vw").style("height", "100vh").style("cursor", "grab").style("display", "block").append("g");

        const svgL = d3.select("#infim-svg-left"); const gL = svgL.select("g");
        const zoomL = d3.zoom().scaleExtent([0.05, 4]).on("zoom", (e) => gL.attr("transform", e.transform));
        svgL.call(zoomL).call(zoomL.transform, d3.zoomIdentity.translate(480, window.innerHeight / 2).scale(0.85));

        const svgR = d3.select("#infim-svg-right"); const gR = svgR.select("g");
        const zoomR = d3.zoom().scaleExtent([0.05, 4]).on("zoom", (e) => gR.attr("transform", e.transform));
        svgR.call(zoomR).call(zoomR.transform, d3.zoomIdentity.translate(480, window.innerHeight / 2).scale(0.95));

        const svgI = d3.select("#infim-svg-items"); const gI = svgI.select("g");
        const zoomI = d3.zoom().scaleExtent([0.05, 4]).on("zoom", (e) => gI.attr("transform", e.transform));
        svgI.call(zoomI).call(zoomI.transform, d3.zoomIdentity.translate(480, window.innerHeight / 2).scale(0.95));

        lSearchInput.onfocus = () => { if(!lSearchInput.value.trim()) {leftSearchKeyword=""; if(drawLocationTreeRef) drawLocationTreeRef();} lTreeBodyContainer.style.display="flex"; lSearchInput.style.borderColor="#52c41a"; };
        lSearchInput.oninput = () => { leftSearchKeyword = lSearchInput.value.trim(); if(drawLocationTreeRef) drawLocationTreeRef(); };
        lRegexBtn.title = isLeftRegexMode ? "模糊搜索(含子串/正则) — 点击切换精确匹配" : "精确匹配 — 点击切换模糊搜索";
        lRegexBtn.onclick = (e) => {
            e.stopPropagation(); isLeftRegexMode = !isLeftRegexMode;
            lRegexBtn.classList.toggle("active", isLeftRegexMode);
            lRegexBtn.title = isLeftRegexMode ? "模糊搜索(含子串/正则) — 点击切换精确匹配" : "精确匹配 — 点击切换模糊搜索";
            lSearchInput.placeholder = isLeftRegexMode ? "输入字符模糊过滤门店/菜单..." : "输入字符精确匹配门店/菜单(完全相等)...";
            if(drawLocationTreeRef) drawLocationTreeRef();
        };
        lCaseBtn.onclick = (e) => { e.stopPropagation(); isLeftCaseSensitive = !isLeftCaseSensitive; lCaseBtn.classList.toggle("active", isLeftCaseSensitive); if(drawLocationTreeRef) drawLocationTreeRef(); };
        lDetailToggleBtn.onclick = (e) => {
            e.stopPropagation();
            window.__infiShowLocationMenus = !window.__infiShowLocationMenus;
            lDetailToggleBtn.classList.toggle("active", window.__infiShowLocationMenus);
            window.__infiLocDetailAutoCenter = true;
            if (window.__infiShowLocationMenus) {
                bulkLoadAllLocationMenus(lDetailToggleBtn);
            } else {
                if (drawLocationTreeRef) drawLocationTreeRef();
            }
        };

        rSearchInput.onfocus = () => { if(!rSearchInput.value.trim()) {rightSearchKeyword=""; if(drawMenuTreeRef) drawMenuTreeRef();} rTreeBodyContainer.style.display="flex"; rSearchInput.style.borderColor="#52c41a"; };
        rSearchInput.oninput = () => { rightSearchKeyword = rSearchInput.value.trim(); if(drawMenuTreeRef) drawMenuTreeRef(); };
        rRegexBtn.title = isRightRegexMode ? "模糊搜索(含子串/正则) — 点击切换精确匹配" : "精确匹配 — 点击切换模糊搜索";
        rRegexBtn.onclick = (e) => {
            e.stopPropagation(); isRightRegexMode = !isRightRegexMode;
            rRegexBtn.classList.toggle("active", isRightRegexMode);
            rRegexBtn.title = isRightRegexMode ? "模糊搜索(含子串/正则) — 点击切换精确匹配" : "精确匹配 — 点击切换模糊搜索";
            rSearchInput.placeholder = isRightRegexMode ? "输入字符模糊过滤Item/Combo..." : "输入字符精确匹配Item/Combo(完全相等)...";
            if(drawMenuTreeRef) drawMenuTreeRef();
        };
        rCaseBtn.onclick = (e) => { e.stopPropagation(); isRightCaseSensitive = !isRightCaseSensitive; rCaseBtn.classList.toggle("active", isRightCaseSensitive); if(drawMenuTreeRef) drawMenuTreeRef(); };
        rDetailToggleBtn.onclick = (e) => { e.stopPropagation(); window.__infiShowSubItems = !window.__infiShowSubItems; rDetailToggleBtn.classList.toggle("active", window.__infiShowSubItems); if(drawMenuTreeRef) drawMenuTreeRef(); };

        iSearchInput.onfocus = () => { if (!iSearchInput.value.trim()) { itemsSearchKeyword = ""; if (drawItemsTreeRef) drawItemsTreeRef(); } iTreeBodyContainer.style.display = "flex"; iSearchInput.style.borderColor = "#52c41a"; };
        iSearchInput.oninput = () => { itemsSearchKeyword = iSearchInput.value.trim(); if (drawItemsTreeRef) drawItemsTreeRef(); };
        iRegexBtn.title = isItemsRegexMode ? "模糊搜索(含子串/正则) — 点击切换精确匹配" : "精确匹配 — 点击切换模糊搜索";
        iRegexBtn.onclick = (e) => {
            e.stopPropagation(); isItemsRegexMode = !isItemsRegexMode;
            iRegexBtn.classList.toggle("active", isItemsRegexMode);
            iRegexBtn.title = isItemsRegexMode ? "模糊搜索(含子串/正则) — 点击切换精确匹配" : "精确匹配 — 点击切换模糊搜索";
            iSearchInput.placeholder = isItemsRegexMode ? "输入字符模糊过滤 Item/Category..." : "输入字符精确匹配(完全相等)...";
            if (drawItemsTreeRef) drawItemsTreeRef();
        };
        iCaseBtn.onclick = (e) => { e.stopPropagation(); isItemsCaseSensitive = !isItemsCaseSensitive; iCaseBtn.classList.toggle("active", isItemsCaseSensitive); if (drawItemsTreeRef) drawItemsTreeRef(); };
        iDetailToggleBtn.onclick = (e) => {
            e.stopPropagation();
            window.__infiShowItemsSubItems = !window.__infiShowItemsSubItems;
            window.__infiItemsDetailAutoCenter = true;
            iDetailToggleBtn.classList.toggle("active", window.__infiShowItemsSubItems);
            if (drawItemsTreeRef) drawItemsTreeRef();
        };
        iToggleAllBtn.onclick = function(e) {
            e.stopPropagation();
            const allCbs = iCategoryDropdown.querySelectorAll('input[type=checkbox]');
            const allChecked = Array.from(allCbs).every(cb => cb.checked);
            allCbs.forEach(cb => { cb.checked = !allChecked; cb.dispatchEvent(new Event('change')); });
        };

        document.addEventListener('click', (e) => {
            if (leftControl && !leftControl.contains(e.target)) { lTreeBodyContainer.style.display="none"; lSearchInput.style.borderColor="#ccc"; }
            if (rightControl && !rightControl.contains(e.target)) { rTreeBodyContainer.style.display="none"; rSearchInput.style.borderColor="#ccc"; }
            if (itemsControl && !itemsControl.contains(e.target)) { iTreeBodyContainer.style.display="none"; iSearchInput.style.borderColor="#ccc"; }
        });
    }

    function showNodeAttributesInPanel(d) {
        if (!d.data.raw) return;
        const tooltipPanel = document.getElementById("infim-tooltip-panel");
        const rawCopy = { ...d.data.raw };
        ['group', 'item_or_combo', 'variations', 'modifier_set', 'modifiers', 'combo_sets', 'items', 'children', '_loadedMenus'].forEach(key => delete rawCopy[key]);

        let htmlContent = `
            <div id="infim-lock-indicator" style="display: ${isPanelLocked ? 'block' : 'none'}; background: #52c41a; color: #fff; text-align: center; font-size: 10px; font-weight: 800; padding: 2px 0; border-radius: 4px; margin-bottom: 8px; letter-spacing: 1px;">面板已锁定 (按 Ctrl 解锁)</div>
            <div style="background: rgba(82, 196, 26, 0.12); padding: 8px 12px; border-radius: 6px; margin-bottom: 12px;">
                <div style="font-size: 10px; color: #52c41a; text-transform: uppercase; letter-spacing: 0.5px; margin-bottom: 2px; font-weight: 900 !important;">节点类型</div>
                <div style="font-size: 16px; color: #000; margin-bottom: 8px; font-weight: 900 !important;">${d.data.type || '无'}</div>
                <div style="font-size: 10px; font-weight: 800; color: #555; text-transform: uppercase; letter-spacing: 0.5px; margin-bottom: 2px;">节点名称</div>
                <div style="font-size: 13px; font-weight: 800; color: #111; word-break: break-all;">${d.data.name || '无'}</div>
            </div>
            <table style="width:100%; border-collapse:collapse; font-size:11px;">`;
        for (const [k, v] of Object.entries(rawCopy)) {
            let dv = typeof v === 'object' ? JSON.stringify(v) : String(v);
            htmlContent += `<tr style="border-bottom: 1px solid rgba(0,0,0,0.06);"><td style="padding:6px 0; color:#9ca3af; font-weight:800; vertical-align:top; width:40%; word-break:break-all;">${k}</td><td class="infim-prop-val-cell" data-copyval="${encodeURIComponent(dv)}" style="padding:6px 0; color:#111; font-weight:700; vertical-align:top; width:60%; word-break:break-all; text-align:right;">${dv}</td></tr>`;
        }
        htmlContent += `</table>`; tooltipPanel.innerHTML = htmlContent; tooltipPanel.style.display = 'block';
        tooltipPanel.querySelectorAll('.infim-prop-val-cell').forEach(cell => { cell.onclick = function(e) { e.stopPropagation(); navigator.clipboard.writeText(decodeURIComponent(this.getAttribute('data-copyval'))).then(() => { let oh = this.innerHTML; this.innerHTML = `<span style="color: #52c41a; font-weight: bold; font-size:11px; margin-right:4px;">✓ 成功 ok</span> ` + oh; setTimeout(() => this.innerHTML = oh, 1000); }); }; });
    }

    // ==========================================
    // 6. 左侧 Location Tree 渲染引擎
    // ==========================================
    function updateLocationUI(payload) {
        const allLocs = payload.locations || [];
        const domTreeRefs = [];
        const groupDropdown = document.getElementById("infim-loc-dropdown");
        groupDropdown.innerHTML = '';

        const selectedLocIds = new Set();
        allLocs.forEach(loc => {
            const locId = loc.location_id || loc.id;
            const locName = loc.name || loc.title || "未命名门店";
            const groupBlock = document.createElement('div'); groupBlock.style = "border-bottom: 1px solid #f5f5f5; padding: 6px 12px;";
            const groupLabel = document.createElement('label'); groupLabel.style = "display:flex; align-items:center; cursor:pointer; gap:8px; flex:1; font-weight:bold; color:#111; font-size:13px;";
            const groupCb = document.createElement('input'); groupCb.type = 'checkbox'; groupCb.checked = true; groupCb.value = locId;
            const groupTextSpan = document.createElement('span');
            groupTextSpan.innerHTML = `<span style="color:#aaa; font-weight:normal; margin-right:4px;">[Location]</span><span>${locName}</span>`;
            groupLabel.appendChild(groupCb); groupLabel.appendChild(groupTextSpan); groupBlock.appendChild(groupLabel); groupDropdown.appendChild(groupBlock);

            groupCb.onchange = () => { if (groupCb.checked) selectedLocIds.add(locId); else selectedLocIds.delete(locId); drawLocationTreeRef(); };
            domTreeRefs.push({ locId, realLocName: locName, block: groupBlock, groupCb, textSpan: groupTextSpan, rawLoc: loc });
            selectedLocIds.add(locId);
        });

        const toggleAllBtn = document.querySelector("#infim-left-search-control button");
        toggleAllBtn.onclick = function(e) {
            e.stopPropagation();
            const visibleRefs = domTreeRefs.filter(gRef => gRef.block.style.display !== 'none');
            if (visibleRefs.length === 0) return;
            const allChecked = visibleRefs.every(gRef => gRef.groupCb.checked);
            visibleRefs.forEach(gRef => { gRef.groupCb.checked = !allChecked; if (!allChecked) selectedLocIds.add(gRef.locId); else selectedLocIds.delete(gRef.locId); });
            drawLocationTreeRef();
        };

        const dx = 60, dy = 550;

        const resetLeftSearchCondition = () => {
            leftSearchKeyword = "";
            document.querySelector('#infim-left-search-control input').value = "";
            const clearBadgeBtn = document.querySelector("#infim-left-search-control .infim-clear-badge-btn");
            if(clearBadgeBtn) clearBadgeBtn.style.display = "none";

            selectedLocIds.clear();
            domTreeRefs.forEach(gRef => {
                gRef.block.style.display = 'block';
                gRef.groupCb.checked = true;
                selectedLocIds.add(gRef.locId);
                gRef.textSpan.innerHTML = `<span style="color:#aaa; font-weight:normal; margin-right:4px;">[Location]</span><span>${gRef.realLocName}</span>`;
            });
            drawLocationTreeRef();
        };

        const highlightText = (el, tag, text, keyword) => {
            const prefix = `<span style="color:#aaa; font-weight:normal; margin-right:4px;">${tag}</span>`;
            if (!keyword) { el.innerHTML = prefix + `<span>${text}</span>`; return; }
            if (!isLeftRegexMode) {
                const lowerText = text.toLowerCase();
                const exactHit = keyword.toLowerCase().split('|').some(seg => { const t = seg.trim(); return t.length > 0 && lowerText === t; });
                if (exactHit) { el.innerHTML = prefix + `<span><span style="color:red; font-weight:bold;">${text}</span></span>`; }
                else { el.innerHTML = prefix + `<span>${text}</span>`; }
                return;
            }
            try {
                const flags = isLeftCaseSensitive ? "g" : "gi";
                const regex = new RegExp(`(${keyword.replace(/[-\/\\^$*+?.()|[\]{}]/g, '\\$&')})`, flags);
                el.innerHTML = prefix + `<span>${text.replace(regex, `<span style="color:red; font-weight:bold;">$1</span>`)}</span>`;
            } catch(ex) {
                const lowerText = text.toLowerCase(); const lowerKey = keyword.toLowerCase(); const idx = lowerText.indexOf(lowerKey);
                if (idx > -1) { el.innerHTML = prefix + `<span>${text.substring(0, idx)}<span style="color:red; font-weight:bold;">${text.substring(idx, idx + keyword.length)}</span>${text.substring(idx + keyword.length)}</span>`; }
                else { el.innerHTML = prefix + `<span>${text}</span>`; }
            }
        };

        // ⭐ 恢复左树的方向判定
        function isTextOnRight(d) { return d.data.type === 'Menu' || (d.data.type === 'Location' && (!d.children || d.children.length === 0)); }

        drawLocationTreeRef = function() {
            const mainGroup = d3.select("#infim-svg-left g");
            mainGroup.selectAll("*").remove();

            let matchCount = 0;
            const rawInput = leftSearchKeyword;

            if (rawInput) {
                selectedLocIds.clear();
                domTreeRefs.forEach(gRef => {
                    let isMatched = safeCheckMatch(rawInput, gRef.realLocName, isLeftRegexMode, isLeftCaseSensitive) || safeCheckMatch(rawInput, gRef.locId, isLeftRegexMode, isLeftCaseSensitive);
                    for (const [k, v] of Object.entries(gRef.rawLoc)) { if (k === '_loadedMenus') continue; if (safeCheckMatch(rawInput, k, isLeftRegexMode, isLeftCaseSensitive)||safeCheckMatch(rawInput, typeof v==='object'?JSON.stringify(v):v, isLeftRegexMode, isLeftCaseSensitive)) isMatched=true; }
                    if (gRef.rawLoc._loadedMenus && Array.isArray(gRef.rawLoc._loadedMenus)) { gRef.rawLoc._loadedMenus.forEach(menu => { if (safeCheckMatch(rawInput, menu.menu_name, isLeftRegexMode, isLeftCaseSensitive) || safeCheckMatch(rawInput, menu.menu_id, isLeftRegexMode, isLeftCaseSensitive)) isMatched = true; }); }
                    if (isMatched) {
                        matchCount++; gRef.block.style.display = 'block'; gRef.groupCb.checked = true; selectedLocIds.add(gRef.locId);
                        highlightText(gRef.textSpan, "[Location]", safeCheckMatch(rawInput, gRef.locId, isLeftRegexMode, isLeftCaseSensitive) ? `${gRef.realLocName} (ID: ${gRef.locId})` : gRef.realLocName, rawInput);
                    }
                    else { gRef.block.style.display = 'none'; gRef.groupCb.checked = false; }
                });
                const clearBadgeBtn = document.querySelector("#infim-left-search-control .infim-clear-badge-btn");
                if(clearBadgeBtn) { clearBadgeBtn.innerHTML = `${matchCount}条符合 <span style="font-size:10px; margin-left:2px;">✕</span>`; clearBadgeBtn.style.display = "flex"; }
            } else {
                domTreeRefs.forEach(gRef => { gRef.block.style.display = 'block'; gRef.textSpan.innerHTML = `<span style="color:#aaa; font-weight:normal; margin-right:4px;">[Location]</span><span>${gRef.realLocName}</span>`;});
                const clearBadgeBtn = document.querySelector("#infim-left-search-control .infim-clear-badge-btn");
                if(clearBadgeBtn) clearBadgeBtn.style.display = "none";
            }

            document.querySelector("#infim-left-search-control .infim-clear-badge-btn").onclick = (e) => {
                e.stopPropagation(); resetLeftSearchCondition();
            };

            if (selectedLocIds.size === 0) return;
            const treeData = transformLocationData(payload, selectedLocIds, leftSearchKeyword);
            if (!treeData.children || treeData.children.length === 0) return;

            const root = d3.hierarchy(treeData);

            root.eachBefore(d => { d.y = d.depth * dy; });
            let leafIndex = 0;
            root.eachAfter(d => {
                if (!d.children || d.children.length === 0) { d.x = leafIndex++ * dx; }
                else { d.x = (d.children[0].x + d.children[d.children.length - 1].x) / 2; }
            });

            const matchedNodesSet = new Set(), pathLinkNodesSet = new Set();
            root.descendants().forEach(d => {
                if (safeCheckMatch(leftSearchKeyword, d.data.name, isLeftRegexMode, isLeftCaseSensitive) || safeCheckMatch(leftSearchKeyword, d.data.id, isLeftRegexMode, isLeftCaseSensitive)) {
                    matchedNodesSet.add(d);
                    d.ancestors().forEach(anc => pathLinkNodesSet.add(anc));
                }
            });

            const linkPathSelection = mainGroup.append("g").attr("fill", "none").selectAll("path").data(root.links()).join("path").attr("d", d3.linkHorizontal().x(d => d.y).y(d => d.x))
                .attr("stroke", d => (leftSearchKeyword && pathLinkNodesSet.has(d.source) && pathLinkNodesSet.has(d.target)) ? LINK_COLOR : "#666666")
                .attr("stroke-opacity", d => (leftSearchKeyword && pathLinkNodesSet.has(d.source) && pathLinkNodesSet.has(d.target)) ? 0.95 : 0.55)
                .attr("stroke-width", d => (leftSearchKeyword && pathLinkNodesSet.has(d.source) && pathLinkNodesSet.has(d.target)) ? 4.5 : 1.6);

            // ⭐ 修复一：给左侧补充高亮连线算法
            function highlightHoverPathLoc(targetNode) {
                const activeNodes = new Set([...targetNode.ancestors(), ...targetNode.descendants()]);
                linkPathSelection
                    .attr("stroke", d => (activeNodes.has(d.source) && activeNodes.has(d.target)) ? LINK_COLOR : (leftSearchKeyword && pathLinkNodesSet.has(d.source) && pathLinkNodesSet.has(d.target) ? LINK_COLOR : "#666666"))
                    .attr("stroke-opacity", d => (activeNodes.has(d.source) && activeNodes.has(d.target)) ? 0.95 : (leftSearchKeyword && pathLinkNodesSet.has(d.source) && pathLinkNodesSet.has(d.target) ? 0.95 : 0.55))
                    .attr("stroke-width", d => (activeNodes.has(d.source) && activeNodes.has(d.target)) ? 4.5 : (leftSearchKeyword && pathLinkNodesSet.has(d.source) && pathLinkNodesSet.has(d.target) ? 4.5 : 1.6));
            }
            function resetHoverHighlightLoc() {
                linkPathSelection
                    .attr("stroke", d => (leftSearchKeyword && pathLinkNodesSet.has(d.source) && pathLinkNodesSet.has(d.target)) ? LINK_COLOR : "#666666")
                    .attr("stroke-opacity", d => (leftSearchKeyword && pathLinkNodesSet.has(d.source) && pathLinkNodesSet.has(d.target)) ? 0.95 : 0.55)
                    .attr("stroke-width", d => (leftSearchKeyword && pathLinkNodesSet.has(d.source) && pathLinkNodesSet.has(d.target)) ? 4.5 : 1.6);
            }

            const node = mainGroup.append("g").attr("stroke-linejoin", "round").attr("stroke-width", 3).selectAll("g")
                .data(root.descendants()).join("g").attr("class", "infim-tree-node-group").attr("transform", d => `translate(${d.y},${d.x})`);

            node.append("circle")
                .attr("fill", d => {
                    let t = d.data.type ? d.data.type.toUpperCase() : "";
                    if (['ITEM', 'COMBO', 'COMBOITEM', 'MOD', 'VAR', 'SET'].includes(t)) {
                        let st = d.data.raw && d.data.raw.status ? String(d.data.raw.status).toUpperCase() : "";
                        if (st === "AVAILABLE") return "#52c41a";
                        if (st === "HIDDEN") return "#f4f4f4";
                    }
                    return d.children ? "#555" : "#999";
                })
                .attr("stroke", d => {
                    let t = d.data.type ? d.data.type.toUpperCase() : "";
                    if (['ITEM', 'COMBO', 'COMBOITEM', 'MOD', 'VAR', 'SET'].includes(t)) {
                        let st = d.data.raw && d.data.raw.status ? String(d.data.raw.status).toUpperCase() : "";
                        if (st === "HIDDEN") return "#ccc";
                    }
                    return "none";
                })
                .attr("stroke-width", 1)
                .attr("r", 5)
                .on("mouseover", (e, d) => { currentHoveredData = d; highlightHoverPathLoc(d); if (!isPanelLocked) showNodeAttributesInPanel(d); })
                .on("mouseout", () => { currentHoveredData = null; resetHoverHighlightLoc(); if (!isPanelLocked) document.getElementById("infim-tooltip-panel").style.display = 'none'; });

            const nameText = node.append("text").attr("class", "infim-tree-name-text infim-tree-name-clickable").attr("dy", "-0.3em")
                .attr("text-anchor", d => isTextOnRight(d) ? "start" : "end").attr("font-weight", "bold")
                .on("mouseover", (e, d) => { currentHoveredData = d; highlightHoverPathLoc(d); if (!isPanelLocked) showNodeAttributesInPanel(d); })
                .on("mouseout", () => { currentHoveredData = null; resetHoverHighlightLoc(); if (!isPanelLocked) document.getElementById("infim-tooltip-panel").style.display = 'none'; })
                .on("click", function(e, d) {
                    if (d.data.name) { e.stopPropagation(); navigator.clipboard.writeText(d.data.name).then(() => { let ce = d3.select(this); ce.selectAll("*").remove(); ce.append("tspan").text("✓ 复制成功 ok").attr("fill", "#52c41a"); setTimeout(() => renderMultiColorText(ce, d), 1200); }); }
                });

            function renderMultiColorText(selection, d) {
                selection.selectAll("*").remove();
                let typeUpper = d.data.type ? d.data.type.toUpperCase() : "";

                if (typeUpper === 'MERCHANT') selection.attr("font-size", "28px");
                else if (typeUpper === 'LOCATION' || typeUpper === 'MENU') selection.attr("font-size", "21px");
                else selection.attr("font-size", "14px");

                if (d.data.type && d.data.type !== 'Type') selection.append("tspan").text(`${d.data.type}: `).attr("fill", "#d946ef").attr("font-weight", "900");

                let isInactive = ['MOD', 'VAR', 'SET'].includes(typeUpper) && d.data.raw && d.data.raw.is_active === false;

                selection.append("tspan").attr("class", "infim-tspan-name")
                    .text(d.data.name).attr("fill", safeCheckMatch(leftSearchKeyword, d.data.name, isLeftRegexMode, isLeftCaseSensitive) ? "red" : (isInactive ? "#999" : "#111111"));

                const childCount = d.children ? d.children.length : 0;
                const isLoc = typeUpper === 'LOCATION';
                const isLoaded = isLoc && d.data.raw && d.data.raw._hasLoadedMenus;
                // When detail toggle is off, menus are not expanded as D3 children.
                // Use _loadedMenus.length as the real count instead of the visible child count.
                const displayCount = (isLoc && isLoaded && childCount === 0 && Array.isArray(d.data.raw._loadedMenus))
                    ? d.data.raw._loadedMenus.length
                    : childCount;

                if (childCount > 0 || isLoaded) {
                    selection.append("tspan").text(` [${displayCount}]`).attr("fill", COUNT_COLOR).attr("font-weight", "bold");
                }
            }

            nameText.each(function(d) {
                let typeUpper = d.data.type ? d.data.type.toUpperCase() : "";
                let isRight = isTextOnRight(d);
                let currentX = isRight ? 8 : -8;

                // Platform icon for Merchant and Menu nodes
                let p = (typeUpper === 'MERCHANT' || typeUpper === 'MENU') && d.data.raw && d.data.raw.platform
                    ? d.data.raw.platform.toUpperCase() : null;
                let hasIcon = p && p !== 'INFI' && ['SQUARE', 'HUNGERRUSH', 'TOAST', 'LIGHTSPEED'].includes(p);
                // Merchant 是根节点，图标放大；Menu 用标准尺寸
                let iconSize = typeUpper === 'MERCHANT' ? 24 : 18;
                if (hasIcon && isRight) currentX += iconSize + 6;

                d3.select(this).attr("x", currentX);
                renderMultiColorText(d3.select(this), d);

                if (hasIcon) {
                    let iconPath = getPlatformIconUrl(p);
                    if (iconPath) {
                        let iconX = isRight ? 8 : (currentX - (this.getComputedTextLength() || 50) - iconSize - 4);
                        let iconY = iconSize === 24 ? -16 : -12;
                        d3.select(this.parentNode).insert("image", "text")
                            .attr("href", window.location.origin + iconPath)
                            .attr("xlink:href", window.location.origin + iconPath)
                            .attr("x", iconX).attr("y", iconY)
                            .attr("width", iconSize).attr("height", iconSize);
                    }
                }

                // 物理绘制紫粉色中划线 (依靠绝对偏移代替getBBox)
                let isInactive = ['MOD', 'VAR', 'SET'].includes(typeUpper) && d.data.raw && d.data.raw.is_active === false;
                if (isInactive) {
                    let textLen = this.getComputedTextLength() || 50;
                    let midY = -9;
                    d3.select(this.parentNode).append("line")
                        .attr("x1", isRight ? currentX : currentX - textLen)
                        .attr("y1", midY)
                        .attr("x2", isRight ? currentX + textLen : currentX)
                        .attr("y2", midY)
                        .attr("stroke", STRIKE_COLOR).attr("stroke-width", 2.5).style("pointer-events", "none");
                }
            });

            nameText.clone(true).lower().attr("class", "").attr("stroke", "rgba(255,255,255,0.85)").attr("stroke-width", 3).on("click", null).on("mouseover", null).on("mouseout", null).selectAll("tspan").attr("fill", null).attr("stroke", "rgba(255,255,255,0.85)");

            const idGroup = node.append("g").attr("class", "infim-id-hotspot-g")
                .on("mouseover", e => { e.stopPropagation(); if (!isPanelLocked) document.getElementById("infim-tooltip-panel").style.display = 'none'; });

            // 保留阻挡穿透魔法
            const idText = idGroup.append("text").attr("class", "infim-tree-id-text").attr("y", 16)
                .style("pointer-events", "none")
                .attr("x", d => {
                    let isRight = isTextOnRight(d);
                    let startX = isRight ? 8 : -8;
                    let pIcon = (d.data.type === 'Merchant' || d.data.type === 'Menu') && d.data.raw && d.data.raw.platform
                        ? d.data.raw.platform.toUpperCase() : null;
                    let hasIconOff = pIcon && pIcon !== 'INFI' && ['SQUARE', 'HUNGERRUSH', 'TOAST', 'LIGHTSPEED'].includes(pIcon);
                    if (hasIconOff && isRight) startX += 24;
                    return startX;
                })
                .attr("text-anchor", d => isTextOnRight(d) ? "start" : "end")
                .text(d => d.data.id && d.data.id !== "N/A" ? `ID: ${d.data.id}` : "")
                .attr("font-size", "13px")
                .attr("fill", d => safeCheckMatch(leftSearchKeyword, d.data.id, isLeftRegexMode, isLeftCaseSensitive) ? "red" : "#666")
                .attr("font-weight", "500");

            idText.each(function(d) {
                if (!d.data.id || d.data.id === "N/A") return;
                const isRight = isTextOnRight(d);
                let startX = isRight ? 8 : -8;
                let pIcon = (d.data.type === 'Merchant' || d.data.type === 'Menu') && d.data.raw && d.data.raw.platform
                    ? d.data.raw.platform.toUpperCase() : null;
                let hasIconOff = pIcon && pIcon !== 'INFI' && ['SQUARE', 'HUNGERRUSH', 'TOAST', 'LIGHTSPEED'].includes(pIcon);
                if (hasIconOff && isRight) startX += 24;
                let textLen = this.getComputedTextLength() || (d.data.id.length * 8);
                let rectX = isRight ? startX - 4 : startX - textLen - 4;

                d3.select(this.parentNode).insert("rect", "text")
                    .attr("class", "id-hotspot-catcher")
                    .attr("y", 2).attr("x", rectX)
                    .attr("width", textLen + 8).attr("height", 18)
                    .attr("fill", "transparent")
                    .style("pointer-events", "all").style("cursor", "pointer")
                    .on("mouseenter", () => { d3.select(this.parentNode).select(".infim-tree-id-text").attr("fill", "#52c41a").style("text-decoration", "underline"); })
                    .on("mouseleave", () => { d3.select(this.parentNode).select(".infim-tree-id-text").attr("fill", safeCheckMatch(leftSearchKeyword, d.data.id, isLeftRegexMode, isLeftCaseSensitive) ? "red" : "#666").style("text-decoration", "none"); })
                    .on("click", function(e) {
                        e.stopPropagation();
                        navigator.clipboard.writeText(d.data.id).then(() => {
                            let tt = d3.select(this.parentNode).select(".infim-tree-id-text");
                            tt.text("✓ ID 复制成功 ok").attr("fill", "#52c41a").style("text-decoration", "none");
                            setTimeout(() => tt.text(`ID: ${d.data.id}`).attr("fill", safeCheckMatch(leftSearchKeyword, d.data.id, isLeftRegexMode, isLeftCaseSensitive) ? "red" : "#666"), 1200);
                        });
                    });

                let currentOffset = isRight ? (startX + textLen + 16) : (startX - textLen - 16);

                if (d.data.type === 'Location') {
                    const isLoaded = d.data.raw && d.data.raw._hasLoadedMenus;
                    const btnStr = isLoaded ? "[↻ Refresh]" : "[Load Menus]";

                    const btnG = d3.select(this.parentNode.parentNode).append("g").style("cursor", "pointer")
                        .on("mouseover", e => { e.stopPropagation(); if (!isPanelLocked) document.getElementById("infim-tooltip-panel").style.display = 'none'; })
                        .on("click", function(evt) { evt.stopPropagation(); evt.preventDefault(); executeLoadLocationMenus(d.data.id, d3.select(this).select(".infim-btn-action").node()); });

                    const btnTxt = btnG.append("text").attr("class", "infim-btn-action").attr("y", 16)
                        .style("pointer-events", "none")
                        .attr("x", isRight ? currentOffset : currentOffset).attr("text-anchor", isRight ? "start" : "end")
                        .text(btnStr).style("fill", "#52c41a").style("font-size", "13px").style("font-weight", "900");

                    let btnLen = btnTxt.node().getComputedTextLength() || 80;
                    let btnRectX = isRight ? currentOffset - 4 : currentOffset - btnLen - 4;
                    btnG.insert("rect", "text").attr("y", 2).attr("x", btnRectX).attr("width", btnLen + 8).attr("height", 18).attr("fill", "transparent").style("pointer-events", "all");
                    currentOffset = isRight ? (currentOffset + btnLen + 12) : (currentOffset - btnLen - 12);
                }

                if (d.data.type === 'Menu') {
                    const btnG = d3.select(this.parentNode.parentNode).append("g").style("cursor", "pointer")
                        .on("mouseover", e => { e.stopPropagation(); if (!isPanelLocked) document.getElementById("infim-tooltip-panel").style.display = 'none'; })
                        .on("click", function(evt) {
                            evt.preventDefault(); evt.stopPropagation();
                            const locId = d.parent && d.parent.data ? d.parent.data.id : null;
                            if (locId) window.__infiCurrentLocationId = locId;
                            loadAndSlideToMenuTree(d.data.id, d3.select(this).select(".infim-btn-action").node(), locId);
                        });

                    const btnTxt = btnG.append("text").attr("class", "infim-btn-action").attr("y", 16)
                        .style("pointer-events", "none")
                        .attr("x", isRight ? currentOffset : currentOffset).attr("text-anchor", isRight ? "start" : "end")
                        .text("[➜ Load Tree]").style("fill", "#52c41a").style("font-size", "13px").style("font-weight", "900");

                    let btnLen = btnTxt.node().getComputedTextLength() || 80;
                    let btnRectX = isRight ? currentOffset - 4 : currentOffset - btnLen - 4;
                    btnG.insert("rect", "text").attr("y", 2).attr("x", btnRectX).attr("width", btnLen + 8).attr("height", 18).attr("fill", "transparent").style("pointer-events", "all");
                }
            });

            const svg = d3.select("#infim-svg-left");
            const zoom = d3.zoom().scaleExtent([0.05, 4]).on("zoom", (event) => mainGroup.attr("transform", event.transform));
            if (window.__infiLocDetailAutoCenter) {
                const nodeCount = root.descendants().length;
                if (window.__infiShowLocationMenus) {
                    const minScale = nodeCount > 200 ? 0.4 : (nodeCount > 80 ? 0.5 : 0.6);
                    autoCenterTree(svg, zoom, root.descendants(), 500, minScale, 0.95);
                } else {
                    autoCenterTree(svg, zoom, root.descendants(), 500, 0.5, 1.1);
                }
                window.__infiLocDetailAutoCenter = false;
            } else if (leftSearchKeyword && matchedNodesSet.size > 0) {
                const focusNodes = root.descendants().filter(d => matchedNodesSet.has(d));
                autoCenterTree(svg, zoom, focusNodes, 500);
            } else if (window.__infiLastLeftKeyword && !leftSearchKeyword) {
                autoCenterTree(svg, zoom, root.descendants(), 500);
            }
            window.__infiLastLeftKeyword = leftSearchKeyword;
        };
        drawLocationTreeRef();
    }

    // ==========================================
    // 7. 右侧 Menu Tree 渲染引擎
    // ==========================================
    // ⭐ 恢复右树专属的方向判定
        function isRightTreeTextOnRight(d) { return !d.children || d.children.length === 0; }

    drawMenuTreeRef = function() {
        const payload = window.__infiMenuPayload;
        if (!payload) return;

        const allGroups = payload.group || [];
        const domTreeRefs = [];
        const groupDropdown = document.getElementById("infim-menu-dropdown");

        const resetRightSearchCondition = () => {
            rightSearchKeyword = "";
            document.querySelector('#infim-right-search-control input').value = "";
            const clearBadgeBtn = document.querySelector("#infim-right-search-control .infim-clear-badge-btn");
            if(clearBadgeBtn) clearBadgeBtn.style.display = "none";

            const selectedGroupIds = new Set();
            const selectedItemIds = new Set();
            const domRefs = window.__infiMenuDomRefs || [];

            domRefs.forEach(gRef => {
                gRef.block.style.display = 'block';
                gRef.itemContainer.style.display = 'none';
                gRef.arrow.style.transform = 'rotate(0deg)';
                gRef.groupCb.checked = true;
                selectedGroupIds.add(gRef.groupId);
                gRef.textSpan.innerHTML = `<span style="color:#aaa; font-weight:normal; margin-right:4px;">[Group]</span><span>${gRef.realGroupName}</span>`;

                gRef.items.forEach(iRef => {
                    iRef.label.style.display = 'flex';
                    iRef.cb.checked = true;
                    const tagStr = iRef.rawItem.type === 'COMBO' ? '[Combo]' : '[Item]';
                    iRef.textSpan.innerHTML = `<span style="color:#aaa; font-weight:normal; margin-right:4px;">${tagStr}</span><span>${iRef.realName}</span>`;
                    selectedItemIds.add(iRef.id);
                });
            });
            window.__infiMenuSelectedGroupIds = selectedGroupIds;
            window.__infiMenuSelectedItemIds = selectedItemIds;
            drawMenuTreeD3(payload, selectedGroupIds, selectedItemIds);
        };

        if(groupDropdown.innerHTML === '') {
            const selectedGroupIds = new Set();
            const selectedItemIds = new Set();
            allGroups.forEach(g => {
                const groupBlock = document.createElement('div'); groupBlock.style = "border-bottom: 1px solid #f5f5f5; padding: 2px 0;";
                const groupLine = document.createElement('div'); groupLine.style = "display:flex; align-items:center; padding:6px 12px; gap:4px;";
                const arrow = document.createElement('span'); arrow.innerText = "▶"; arrow.style = "cursor:pointer; width:16px; display:inline-block; font-size:11px; color:#aaa; transition: transform 0.2s;";
                const groupLabel = document.createElement('label'); groupLabel.style = "display:flex; align-items:center; cursor:pointer; gap:8px; flex:1; font-weight:bold; color:#111; font-size:13px;";
                const groupCb = document.createElement('input'); groupCb.type = 'checkbox'; groupCb.checked = true; groupCb.value = g.group_id;
                const groupTextSpan = document.createElement('span'); groupTextSpan.innerHTML = `<span style="color:#aaa; font-weight:normal; margin-right:4px;">[Group]</span><span>${g.name}</span>`;

                groupLabel.appendChild(groupCb); groupLabel.appendChild(groupTextSpan); groupLine.appendChild(arrow); groupLine.appendChild(groupLabel); groupBlock.appendChild(groupLine);

                const itemContainer = document.createElement('div'); itemContainer.style = "display:none; padding-left:32px; flex-direction:column; gap:2px; margin-top:2px;";
                const itemRefs = [];
                if (g.item_or_combo && Array.isArray(g.item_or_combo)) {
                    g.item_or_combo.forEach(item => {
                        const itemLabel = document.createElement('label'); itemLabel.style = "display:flex; align-items:center; padding:4px 0; cursor:pointer; gap:8px; color:#555; font-size:13px;";
                        const itemCb = document.createElement('input'); itemCb.type = 'checkbox'; itemCb.checked = true; itemCb.value = item.id;
                        const itemTextSpan = document.createElement('span');
                        const tagStr = item.type === 'COMBO' ? '[Combo]' : '[Item]';
                        itemTextSpan.innerHTML = `<span style="color:#aaa; font-weight:normal; margin-right:4px;">${tagStr}</span><span>${item.name}</span>`;

                        itemCb.onchange = (e) => {
                            if (e.target.checked) { selectedItemIds.add(item.id); if (!groupCb.checked) { groupCb.checked = true; selectedGroupIds.add(g.group_id); } }
                            else { selectedItemIds.delete(item.id); }
                            drawMenuTreeD3(payload, selectedGroupIds, selectedItemIds);
                        };

                        itemLabel.appendChild(itemCb); itemLabel.appendChild(itemTextSpan); itemContainer.appendChild(itemLabel);
                        itemRefs.push({ id: item.id, realName: item.name, cb: itemCb, label: itemLabel, textSpan: itemTextSpan, rawItem: item });
                        selectedItemIds.add(item.id);
                    });
                }
                groupBlock.appendChild(itemContainer); groupDropdown.appendChild(groupBlock);

                groupCb.onchange = (e) => {
                    if (e.target.checked) {
                        selectedGroupIds.add(g.group_id);
                        itemRefs.forEach(itemObj => { if (itemObj.label.style.display !== 'none') { itemObj.cb.checked = true; selectedItemIds.add(itemObj.id); } });
                    } else {
                        selectedGroupIds.delete(g.group_id);
                        itemRefs.forEach(itemObj => { if (itemObj.label.style.display !== 'none') { itemObj.cb.checked = false; selectedItemIds.delete(itemObj.id); } });
                    }
                    drawMenuTreeD3(payload, selectedGroupIds, selectedItemIds);
                };

                arrow.onclick = (e) => { e.stopPropagation(); const isCol = itemContainer.style.display === 'none'; itemContainer.style.display = isCol ? 'flex' : 'none'; arrow.style.transform = isCol ? 'rotate(90deg)' : 'rotate(0deg)'; };

                domTreeRefs.push({ groupId: g.group_id, realGroupName: g.name, block: groupBlock, groupCb: groupCb, arrow: arrow, itemContainer: itemContainer, textSpan: groupTextSpan, items: itemRefs, rawGroup: g });
                selectedGroupIds.add(g.group_id);
            });

            document.querySelector("#infim-right-search-control button").onclick = function(e) {
                e.stopPropagation();
                const visibleRefs = domTreeRefs.filter(gRef => gRef.block.style.display !== 'none');
                if (visibleRefs.length === 0) return;
                const allChecked = visibleRefs.every(gRef => gRef.groupCb.checked);
                visibleRefs.forEach(gRef => {
                    gRef.groupCb.checked = !allChecked;
                    if (!allChecked) selectedGroupIds.add(gRef.groupId); else selectedGroupIds.delete(gRef.groupId);
                    gRef.items.forEach(iRef => {
                        if (iRef.label.style.display !== 'none') {
                            iRef.cb.checked = !allChecked;
                            if (!allChecked) selectedItemIds.add(iRef.id); else selectedItemIds.delete(iRef.id);
                        }
                    });
                });
                drawMenuTreeD3(payload, selectedGroupIds, selectedItemIds);
            };

            window.__infiMenuDomRefs = domTreeRefs;
            window.__infiMenuSelectedGroupIds = selectedGroupIds;
            window.__infiMenuSelectedItemIds = selectedItemIds;
        }

        const domRefs = window.__infiMenuDomRefs || [];
        const selectedGroupIds = window.__infiMenuSelectedGroupIds || new Set();
        const selectedItemIds = window.__infiMenuSelectedItemIds || new Set();

        const highlightText = (el, tag, text, keyword) => {
            const prefix = `<span style="color:#aaa; font-weight:normal; margin-right:4px;">${tag}</span>`;
            if (!keyword) { el.innerHTML = prefix + `<span>${text}</span>`; return; }
            if (!isRightRegexMode) {
                const lowerText = text.toLowerCase();
                const exactHit = keyword.toLowerCase().split('|').some(seg => { const t = seg.trim(); return t.length > 0 && lowerText === t; });
                if (exactHit) { el.innerHTML = prefix + `<span><span style="color:red; font-weight:bold;">${text}</span></span>`; }
                else { el.innerHTML = prefix + `<span>${text}</span>`; }
                return;
            }
            try {
                const flags = isRightCaseSensitive ? "g" : "gi";
                const regex = new RegExp(`(${keyword.replace(/[-\/\\^$*+?.()|[\]{}]/g, '\\$&')})`, flags);
                el.innerHTML = prefix + `<span>${text.replace(regex, `<span style="color:red; font-weight:bold;">$1</span>`)}</span>`;
            } catch(ex) {
                const lowerText = text.toLowerCase(); const lowerKey = keyword.toLowerCase(); const idx = lowerText.indexOf(lowerKey);
                if (idx > -1) { el.innerHTML = prefix + `<span>${text.substring(0, idx)}<span style="color:red; font-weight:bold;">${text.substring(idx, idx + keyword.length)}</span>${text.substring(idx + keyword.length)}</span>`; }
                else { el.innerHTML = prefix + `<span>${text}</span>`; }
            }
        };

        let matchCount = 0;
        const rawInput = rightSearchKeyword;
        if (rawInput) {
            selectedGroupIds.clear(); selectedItemIds.clear();
            domRefs.forEach(gRef => {
                const g = gRef.rawGroup;
                let isGroupMatchedSelf = safeCheckMatch(rawInput, g.name, isRightRegexMode, isRightCaseSensitive) || safeCheckMatch(rawInput, g.group_id, isRightRegexMode, isRightCaseSensitive);
                if (isGroupMatchedSelf) matchCount++;

                let anyChildMatched = false;
                gRef.items.forEach(iRef => {
                    const item = iRef.rawItem;
                    let isItemMatchedSelf = safeCheckMatch(rawInput, item.name, isRightRegexMode, isRightCaseSensitive) || safeCheckMatch(rawInput, item.id, isRightRegexMode, isRightCaseSensitive);
                    let isDeepMatched = false;

                    if (item.combo_sets && Array.isArray(item.combo_sets)) {
                        item.combo_sets.forEach(cs => {
                            if (safeCheckMatch(rawInput, cs.title, isRightRegexMode, isRightCaseSensitive) || safeCheckMatch(rawInput, cs.id, isRightRegexMode, isRightCaseSensitive)) isDeepMatched = true;
                            if (cs.items && Array.isArray(cs.items)) cs.items.forEach(ci => {
                                if (safeCheckMatch(rawInput, ci.title, isRightRegexMode, isRightCaseSensitive) || safeCheckMatch(rawInput, ci.id, isRightRegexMode, isRightCaseSensitive)) isDeepMatched = true;
                            });
                        });
                    }
                    if (item.variations && Array.isArray(item.variations)) item.variations.forEach(v => { if (safeCheckMatch(rawInput, v.name, isRightRegexMode, isRightCaseSensitive) || safeCheckMatch(rawInput, v.id, isRightRegexMode, isRightCaseSensitive)) isDeepMatched = true; });
                    if (item.modifier_set && Array.isArray(item.modifier_set)) item.modifier_set.forEach(ms => {
                        if (safeCheckMatch(rawInput, ms.name, isRightRegexMode, isRightCaseSensitive) || safeCheckMatch(rawInput, ms.modifier_set_id, isRightRegexMode, isRightCaseSensitive)) isDeepMatched = true;
                        if (ms.modifiers && Array.isArray(ms.modifiers)) ms.modifiers.forEach(m => { if (safeCheckMatch(rawInput, m.name, isRightRegexMode, isRightCaseSensitive) || safeCheckMatch(rawInput, m.modifier_id, isRightRegexMode, isRightCaseSensitive)) isDeepMatched = true; });
                    });

                    if (isItemMatchedSelf || isDeepMatched) {
                        matchCount++; iRef.label.style.display = 'flex';
                        const tagStr = item.type === 'COMBO' ? '[Combo]' : '[Item]';
                        highlightText(iRef.textSpan, tagStr, safeCheckMatch(rawInput, item.id, isRightRegexMode, isRightCaseSensitive) ? `${iRef.realName} (ID: ${item.id})` : iRef.realName, rawInput);
                        iRef.cb.checked = true; selectedItemIds.add(iRef.id);
                        anyChildMatched = true;
                    } else { iRef.label.style.display = 'none'; iRef.cb.checked = false; }
                });

                if (isGroupMatchedSelf || anyChildMatched) {
                    gRef.block.style.display = 'block'; gRef.groupCb.checked = true; selectedGroupIds.add(gRef.groupId);
                    if (isGroupMatchedSelf) {
                        highlightText(gRef.textSpan, "[Group]", safeCheckMatch(rawInput, g.group_id, isRightRegexMode, isRightCaseSensitive) ? `${gRef.realGroupName} (ID: ${g.group_id})` : gRef.realGroupName, rawInput);
                        if (!anyChildMatched) gRef.items.forEach(iRef => {
                            iRef.label.style.display = 'flex';
                            iRef.textSpan.innerHTML = `<span style="color:#aaa; font-weight:normal; margin-right:4px;">[${iRef.rawItem.type === 'COMBO' ? 'Combo' : 'Item'}]</span><span>${iRef.realName}</span>`;
                            iRef.cb.checked = true; selectedItemIds.add(iRef.id);
                        });
                    } else { gRef.textSpan.innerHTML = `<span style="color:#aaa; font-weight:normal; margin-right:4px;">[Group]</span><span>${gRef.realGroupName}</span>`; }
                    gRef.itemContainer.style.display = anyChildMatched ? 'flex' : 'none';
                    gRef.arrow.style.transform = anyChildMatched ? 'rotate(90deg)' : 'rotate(0deg)';
                } else { gRef.block.style.display = 'none'; gRef.groupCb.checked = false; }
            });
            const clearBadgeBtn = document.querySelector("#infim-right-search-control .infim-clear-badge-btn");
            if(clearBadgeBtn) { clearBadgeBtn.innerHTML = `${matchCount}条结果 <span style="font-size:10px; margin-left:2px;">✕</span>`; clearBadgeBtn.style.display = "flex"; }
        } else {
            domRefs.forEach(gRef => {
                gRef.block.style.display = 'block'; gRef.itemContainer.style.display = 'none'; gRef.arrow.style.transform = 'rotate(0deg)';
                gRef.textSpan.innerHTML = `<span style="color:#aaa; font-weight:normal; margin-right:4px;">[Group]</span><span>${gRef.realGroupName}</span>`;
                gRef.groupCb.checked = true; selectedGroupIds.add(gRef.groupId);
                gRef.items.forEach(iRef => {
                    iRef.label.style.display = 'flex';
                    iRef.textSpan.innerHTML = `<span style="color:#aaa; font-weight:normal; margin-right:4px;">[${iRef.rawItem.type === 'COMBO' ? 'Combo' : 'Item'}]</span><span>${iRef.realName}</span>`;
                    iRef.cb.checked = true; selectedItemIds.add(iRef.id);
                });
            });
            const clearBadgeBtn = document.querySelector("#infim-right-search-control .infim-clear-badge-btn");
            if(clearBadgeBtn) clearBadgeBtn.style.display = "none";
        }

        document.querySelector("#infim-right-search-control .infim-clear-badge-btn").onclick = (e) => {
            e.stopPropagation(); resetRightSearchCondition();
        };

        drawMenuTreeD3(payload, selectedGroupIds, selectedItemIds);
    };

    function drawMenuTreeD3(payload, validGroupIds, validItemIds) {
        const mainGroup = d3.select("#infim-svg-right g");
        mainGroup.selectAll("*").remove();

        const keyword = rightSearchKeyword.trim();
        const treeData = transformMenuDataForD3(payload, validGroupIds, validItemIds, window.__infiShowSubItems, keyword);
        if (!treeData) return;

        const root = d3.hierarchy(treeData);

        const dx = 42;
        const dy = 340;
        const tree = d3.tree().nodeSize([dx, dy]);
        tree(root);

        const matchedNodesSet = new Set();
        const pathLinkNodesSet = new Set();

        root.descendants().forEach(d => {
            let hit = safeCheckMatch(keyword, d.data.name, isRightRegexMode, isRightCaseSensitive) || safeCheckMatch(keyword, d.data.id, isRightRegexMode, isRightCaseSensitive);
            if (hit) {
                matchedNodesSet.add(d);
                d.ancestors().forEach(anc => pathLinkNodesSet.add(anc));
            }
        });

        const linksData = root.links();
        const linkPathSelection = mainGroup.append("g")
            .attr("fill", "none")
            .selectAll("path")
            .data(linksData)
            .join("path")
            .attr("d", d3.linkHorizontal().x(d => d.y).y(d => d.x))
            .attr("stroke", d => (keyword && pathLinkNodesSet.has(d.source) && pathLinkNodesSet.has(d.target)) ? LINK_COLOR : "#666666")
            .attr("stroke-opacity", d => (keyword && pathLinkNodesSet.has(d.source) && pathLinkNodesSet.has(d.target)) ? 0.95 : 0.55)
            .attr("stroke-width", d => (keyword && pathLinkNodesSet.has(d.source) && pathLinkNodesSet.has(d.target)) ? 4.5 : 1.6);

        function highlightHoverPath(targetNode) {
            const activeNodes = new Set([...targetNode.ancestors(), ...targetNode.descendants()]);
            linkPathSelection
                .attr("stroke", d => (activeNodes.has(d.source) && activeNodes.has(d.target)) ? LINK_COLOR : (keyword && pathLinkNodesSet.has(d.source) && pathLinkNodesSet.has(d.target) ? LINK_COLOR : "#666666"))
                .attr("stroke-opacity", d => (activeNodes.has(d.source) && activeNodes.has(d.target)) ? 0.95 : (keyword && pathLinkNodesSet.has(d.source) && pathLinkNodesSet.has(d.target) ? 0.95 : 0.55))
                .attr("stroke-width", d => (activeNodes.has(d.source) && activeNodes.has(d.target)) ? 4.5 : (keyword && pathLinkNodesSet.has(d.source) && pathLinkNodesSet.has(d.target) ? 4.5 : 1.6));
        }

        function resetHoverHighlight() {
            linkPathSelection
                .attr("stroke", d => (keyword && pathLinkNodesSet.has(d.source) && pathLinkNodesSet.has(d.target)) ? LINK_COLOR : "#666666")
                .attr("stroke-opacity", d => (keyword && pathLinkNodesSet.has(d.source) && pathLinkNodesSet.has(d.target)) ? 0.95 : 0.55)
                .attr("stroke-width", d => (keyword && pathLinkNodesSet.has(d.source) && pathLinkNodesSet.has(d.target)) ? 4.5 : 1.6);
        }

        const node = mainGroup.append("g")
            .attr("stroke-linejoin", "round")
            .attr("stroke-width", 3)
            .selectAll("g")
            .data(root.descendants())
            .join("g")
            .attr("transform", d => `translate(${d.y},${d.x})`);

        node.append("circle")
            .attr("fill", d => {
                let t = d.data.type ? d.data.type.toUpperCase() : "";
                if (['ITEM', 'COMBO', 'COMBOITEM', 'MOD', 'VAR', 'SET'].includes(t)) {
                    let st = d.data.raw && d.data.raw.status ? String(d.data.raw.status).toUpperCase() : "";
                    if (st === "AVAILABLE") return "#52c41a";
                    if (st === "HIDDEN") return "#f4f4f4";
                }
                return d.children ? "#555" : "#999";
            })
            .attr("stroke", d => {
                let t = d.data.type ? d.data.type.toUpperCase() : "";
                if (['ITEM', 'COMBO', 'COMBOITEM', 'MOD', 'VAR', 'SET'].includes(t)) {
                    let st = d.data.raw && d.data.raw.status ? String(d.data.raw.status).toUpperCase() : "";
                    if (st === "HIDDEN") return "#ccc";
                }
                return "none";
            })
            .attr("stroke-width", 1)
            .attr("r", 5)
            .on("mouseover", (event, d) => { currentHoveredData = d; highlightHoverPath(d); if (!isPanelLocked) showNodeAttributesInPanel(d); })
            .on("mouseout", () => { currentHoveredData = null; if (!isPanelLocked) { resetHoverHighlight(); document.getElementById("infim-tooltip-panel").style.display = 'none'; } });

        const nameText = node.append("text")
            .attr("class", "infim-tree-name-text infim-tree-name-clickable")
            .attr("dy", "-0.3em")
            .attr("text-anchor", d => isRightTreeTextOnRight(d) ? "start" : "end").attr("font-weight", "bold")
            .on("mouseover", (event, d) => { currentHoveredData = d; highlightHoverPath(d); if (!isPanelLocked) showNodeAttributesInPanel(d); })
            .on("mouseout", () => { currentHoveredData = null; if (!isPanelLocked) { resetHoverHighlight(); document.getElementById("infim-tooltip-panel").style.display = 'none'; } })
            .on("click", function(event, d) {
                if (d.data.name) {
                    event.stopPropagation();
                    navigator.clipboard.writeText(d.data.name).then(() => {
                        const currentElement = d3.select(this);
                        currentElement.selectAll("*").remove();
                        currentElement.append("tspan").text("✓ 复制成功 ok").attr("fill", "#52c41a").attr("font-weight", "bold");
                        setTimeout(() => { renderMultiColorText(currentElement, d); }, 1200);
                    });
                }
            });

        function renderMultiColorText(selection, d) {
            selection.selectAll("*").remove();
            let typeUpper = d.data.type ? d.data.type.toUpperCase() : "";

            if (typeUpper === 'MENU' || typeUpper === 'MENU ROOT' || typeUpper === 'MERCHANT') selection.attr("font-size", "28px");
            else if (typeUpper === 'GROUP' || typeUpper === 'LOCATION') selection.attr("font-size", "21px");
            else selection.attr("font-size", "14px");

            if (d.data.type && d.data.type !== 'Type') selection.append("tspan").text(`${d.data.type}: `).attr("fill", "#d946ef").attr("font-weight", "900");

            selection.append("tspan").attr("class", "infim-tspan-name")
                .text(d.data.name).attr("fill", safeCheckMatch(rightSearchKeyword, d.data.name, isRightRegexMode, isRightCaseSensitive) ? "red" : "#111111");

            if (['ITEM', 'COMBO', 'COMBOITEM', 'MOD', 'VAR', 'COMBOSET'].includes(typeUpper)) {
                const priceStr = getNodePrice(d.data.raw, typeUpper);
                if (priceStr !== null) {
                    selection.append("tspan").text(` ${priceStr}`).attr("fill", PRICE_COLOR).attr("font-weight", "700");
                }
            }

            const childCount = d.children ? d.children.length : 0;
            const isLoc = typeUpper === 'LOCATION';
            const isLoaded = isLoc && d.data.raw && d.data.raw._hasLoadedMenus;

            if (childCount > 0 || isLoaded) {
                selection.append("tspan").text(` [${childCount}]`).attr("fill", COUNT_COLOR).attr("font-weight", "bold");
            }
        }

        nameText.each(function(d) {
            let typeUpper = d.data.type ? d.data.type.toUpperCase() : "";
            let p = d.data.raw && d.data.raw.platform ? d.data.raw.platform.toUpperCase() : null;
            // ⭐ INFI 绝对不显示，其它符合的强制在文本最前面生成
            let hasIcon = p && p !== 'INFI' && ['SQUARE', 'HUNGERRUSH', 'TOAST', 'LIGHTSPEED'].includes(p);
            // Menu/Menu Root 是树的根节点，图标放大；其它节点用标准尺寸
            let iconSize = (typeUpper === 'MENU' || typeUpper === 'MENU ROOT') ? 24 : 18;

            let isRight = isRightTreeTextOnRight(d);
            let currentX = isRight ? 8 : -8;
            if (hasIcon && isRight) currentX += iconSize + 6; // 在右侧时，给前面的 Icon 让路

            d3.select(this).attr("x", currentX);
            renderMultiColorText(d3.select(this), d);

            // ⭐ 抛除一切玄学报错的直接绝对坐标渲染
            if (hasIcon) {
                let iconPath = getPlatformIconUrl(p);
                if (iconPath) {
                    let iconX;
                    if (isRight) {
                        iconX = 8; // 排在右边，则图标永远钉在起跑线
                    } else {
                        let textLen = this.getComputedTextLength() || 50;
                        iconX = currentX - textLen - iconSize - 4; // 排在左边，算准文本宽度，插在最远端的前面
                    }
                    let iconY = iconSize === 24 ? -16 : -12;
                    d3.select(this.parentNode).insert("image", "text")
                        .attr("href", window.location.origin + iconPath)
                        .attr("xlink:href", window.location.origin + iconPath)
                        .attr("x", iconX)
                        .attr("y", iconY)
                        .attr("width", iconSize)
                        .attr("height", iconSize);
                }
            }

            // 物理绘制紫粉色中划线 (依靠绝对偏移代替getBBox)
            let isInactive = ['MOD', 'VAR', 'SET'].includes(typeUpper) && d.data.raw && d.data.raw.is_active === false;
            if (isInactive) {
                let textLen = this.getComputedTextLength() || 50;
                // midY: baseline(dy=-0.3em=-4.2px for 14px font) - 0.35*14 ≈ -9, proper strikethrough center
                let midY = -9;

                d3.select(this).select(".infim-tspan-name").attr("fill", safeCheckMatch(rightSearchKeyword, d.data.name, isRightRegexMode, isRightCaseSensitive) ? "red" : "#999");

                d3.select(this.parentNode).append("line")
                    .attr("x1", isRight ? currentX : currentX - textLen)
                    .attr("y1", midY)
                    .attr("x2", isRight ? currentX + textLen : currentX)
                    .attr("y2", midY)
                    .attr("stroke", STRIKE_COLOR)
                    .attr("stroke-width", 2.5)
                    .style("pointer-events", "none");
            }

            // 隐藏眼球
            let isHidden = typeUpper === 'MOD' && d.data.raw && d.data.raw.hasOwnProperty('is_client_visible') && d.data.raw.is_client_visible === false;
            if (isHidden) {
                let textLen = this.getComputedTextLength() || 50;
                let eyeX = isRight ? currentX + textLen + 6 : currentX - textLen - 6 - 14;
                d3.select(this.parentNode).append("g")
                    .attr("transform", `translate(${eyeX}, -12)`)
                    .html(`<svg viewBox="0 0 24 24" width="14" height="14" stroke="#999" stroke-width="2.5" fill="none" stroke-linecap="round" stroke-linejoin="round"><path d="M17.94 17.94A10.07 10.07 0 0 1 12 20c-7 0-11-8-11-8a18.45 18.45 0 0 1 5.06-5.94M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 8 11 8a18.5 18.5 0 0 1-2.16 3.19m-6.72-1.07a3 3 0 1 1-4.24-4.24"></path><line x1="1" y1="1" x2="23" y2="23"></line></svg>`);
            }
        });

        nameText.clone(true).lower().attr("class", "").attr("stroke", "rgba(255,255,255,0.85)").attr("stroke-width", 3).on("click", null).on("mouseover", null).on("mouseout", null).selectAll("tspan").attr("fill", null).attr("stroke", "rgba(255,255,255,0.85)");

        const idGroup = node.append("g").attr("class", "infim-id-hotspot-g")
            .on("mouseover", e => { e.stopPropagation(); if (!isPanelLocked) document.getElementById("infim-tooltip-panel").style.display = 'none'; });

        // 保留阻挡穿透魔法
        const idText = idGroup.append("text").attr("class", "infim-tree-id-text").attr("y", 16)
            .style("pointer-events", "none")
            .attr("x", d => {
                let typeUpper = d.data.type ? d.data.type.toUpperCase() : "";
                let p = d.data.raw && d.data.raw.platform ? d.data.raw.platform.toUpperCase() : null;
                let hasIcon = p && p !== 'INFI' && ['SQUARE', 'HUNGERRUSH', 'TOAST', 'LIGHTSPEED'].includes(p);
                let isRight = isRightTreeTextOnRight(d);
                let startX = isRight ? 8 : -8;
                if (hasIcon && isRight) {
                    let iconSize = (typeUpper === 'MENU' || typeUpper === 'MENU ROOT') ? 24 : 18;
                    startX += iconSize + 6;
                }
                return startX;
            })
            .attr("text-anchor", d => isRightTreeTextOnRight(d) ? "start" : "end")
            .text(d => d.data.id && d.data.id !== "N/A" ? `ID: ${d.data.id}` : "")
            .attr("font-size", "13px")
            .attr("fill", d => safeCheckMatch(rightSearchKeyword, d.data.id, isRightRegexMode, isRightCaseSensitive) ? "red" : "#666")
            .attr("font-weight", "500");

        idText.each(function(d) {
            if (!d.data.id || d.data.id === "N/A") return;
            let typeUpper = d.data.type ? d.data.type.toUpperCase() : "";
            let p = d.data.raw && d.data.raw.platform ? d.data.raw.platform.toUpperCase() : null;
            let hasIcon = p && p !== 'INFI' && ['SQUARE', 'HUNGERRUSH', 'TOAST', 'LIGHTSPEED'].includes(p);
            let isRight = isRightTreeTextOnRight(d);

            let startX = isRight ? 8 : -8;
            if (hasIcon && isRight) {
                let iconSize = (typeUpper === 'MENU' || typeUpper === 'MENU ROOT') ? 24 : 18;
                startX += iconSize + 6;
            }

            let textLen = this.getComputedTextLength() || (d.data.id.length * 8);
            let rectX = isRight ? startX - 4 : startX - textLen - 4;

            d3.select(this.parentNode).insert("rect", "text")
                .attr("class", "id-hotspot-catcher")
                .attr("y", 2).attr("x", rectX)
                .attr("width", textLen + 8).attr("height", 18)
                .attr("fill", "transparent")
                .style("pointer-events", "all").style("cursor", "pointer")
                .on("mouseenter", () => { d3.select(this.parentNode).select(".infim-tree-id-text").attr("fill", "#52c41a").style("text-decoration", "underline"); })
                .on("mouseleave", () => { d3.select(this.parentNode).select(".infim-tree-id-text").attr("fill", safeCheckMatch(rightSearchKeyword, d.data.id, isRightRegexMode, isRightCaseSensitive) ? "red" : "#666").style("text-decoration", "none"); })
                .on("click", function(e) {
                    e.stopPropagation();
                    navigator.clipboard.writeText(d.data.id).then(() => {
                        let tt = d3.select(this.parentNode).select(".infim-tree-id-text");
                        tt.text("✓ ID 复制成功 ok").attr("fill", "#52c41a").style("text-decoration", "none");
                        setTimeout(() => tt.text(`ID: ${d.data.id}`).attr("fill", safeCheckMatch(rightSearchKeyword, d.data.id, isRightRegexMode, isRightCaseSensitive) ? "red" : "#666"), 1200);
                    });
                });
        });

        const svg = d3.select("#infim-svg-right");
        const zoom = d3.zoom().scaleExtent([0.05, 4]).on("zoom", (event) => mainGroup.attr("transform", event.transform));

        if (window.__infiForceMenuAutoCenter) {
            autoCenterTree(svg, zoom, root.descendants(), 500, 0.6);
            window.__infiForceMenuAutoCenter = false;
        } else if (rightSearchKeyword && matchedNodesSet.size > 0) {
            const focusNodes = root.descendants().filter(d => matchedNodesSet.has(d));
            autoCenterTree(svg, zoom, focusNodes, 500);
        } else if (window.__infiLastRightKeyword && !rightSearchKeyword) {
            autoCenterTree(svg, zoom, root.descendants(), 500);
        }
        window.__infiLastRightKeyword = rightSearchKeyword;
    }

    // ==========================================
    // 8. Items Library Tree 渲染引擎
    // ==========================================

    function transformItemsDataForD3(payload, showSub, keyword) {
        const root = { type: 'LIBRARY', name: 'categories', id: 'root', children: [] };
        if (!payload || !Array.isArray(payload)) return root;

        // When there's a keyword, always expand sub-nodes so they can be searched
        const expandSub = showSub || !!keyword;

        payload.forEach(category => {
            const catKey = category.key || '';
            const catName = category.title || 'Unknown';
            const catHit = safeCheckMatch(keyword, catName, isItemsRegexMode, isItemsCaseSensitive) ||
                           safeCheckMatch(keyword, catKey, isItemsRegexMode, isItemsCaseSensitive);
            const catNode = { type: 'Category', name: catName, id: catKey, children: [], raw: { catalog_type: 'CATEGORY', key: catKey, title: catName } };

            if (category.children && Array.isArray(category.children)) {
                category.children.forEach(item => {
                    const itemKey = item.key || '';
                    const itemName = item.title || 'Unknown';
                    const itemPlatform = (item.import_type || '').toUpperCase();
                    const itemHit = safeCheckMatch(keyword, itemName, isItemsRegexMode, isItemsCaseSensitive) ||
                                    safeCheckMatch(keyword, itemKey, isItemsRegexMode, isItemsCaseSensitive);

                    const itemNode = {
                        type: 'Item',
                        name: itemName,
                        id: itemKey,
                        children: [],
                        raw: { ...item, children: undefined, platform: itemPlatform, import_type: itemPlatform }
                    };

                    if (expandSub) {
                        // ── Variations group ──────────────────────────────
                        const varChildren = [];
                        if (item.children && Array.isArray(item.children)) {
                            item.children.forEach(variation => {
                                const varKey = variation.key || '';
                                const varName = variation.title || 'Unknown';
                                const varHit = safeCheckMatch(keyword, varName, isItemsRegexMode, isItemsCaseSensitive) ||
                                               safeCheckMatch(keyword, varKey, isItemsRegexMode, isItemsCaseSensitive);
                                if (!keyword || varHit || itemHit || catHit) {
                                    varChildren.push({ type: 'Var', name: varName, id: varKey, raw: { ...variation, catalog_type: 'VARIATION' } });
                                }
                            });
                        }
                        if (varChildren.length > 0) {
                            itemNode.children.push({ type: 'VarGroup', name: 'Variations', id: '', children: varChildren, raw: {} });
                        }

                        // ── Modifier Sets group ───────────────────────────
                        const setChildren = [];
                        if (item.modifier_set && Array.isArray(item.modifier_set)) {
                            item.modifier_set.forEach(ms => {
                                const msId = ms.modifier_set_id || '';
                                const msName = ms.display_name || ms.name || 'Unknown';
                                const msPlatform = (window.__infiModifierSetsMap[msId] || '').toUpperCase();
                                const msHit = safeCheckMatch(keyword, msName, isItemsRegexMode, isItemsCaseSensitive) ||
                                              safeCheckMatch(keyword, msId, isItemsRegexMode, isItemsCaseSensitive);
                                const msNode = {
                                    type: 'Set',
                                    name: msName,
                                    id: msId,
                                    children: [],
                                    raw: { ...ms, platform: msPlatform, import_type: msPlatform, catalog_type: 'MODIFIER_SET' }
                                };
                                if (ms.modifiers && Array.isArray(ms.modifiers)) {
                                    ms.modifiers.forEach(mod => {
                                        const modName = typeof mod === 'string' ? mod : (mod.name || 'Unknown');
                                        const modId = typeof mod === 'string' ? '' : (mod.modifier_id || '');
                                        const modHit = safeCheckMatch(keyword, modName, isItemsRegexMode, isItemsCaseSensitive) ||
                                                       safeCheckMatch(keyword, modId, isItemsRegexMode, isItemsCaseSensitive);
                                        if (!keyword || modHit || msHit || itemHit || catHit) {
                                            msNode.children.push({ type: 'Mod', name: modName, id: modId, raw: { name: modName, modifier_id: modId } });
                                        }
                                    });
                                }
                                if (!keyword || msHit || msNode.children.length > 0 || itemHit || catHit) {
                                    setChildren.push(msNode);
                                }
                            });
                        }
                        if (setChildren.length > 0) {
                            itemNode.children.push({ type: 'SetGroup', name: 'Modifier Sets', id: '', children: setChildren, raw: {} });
                        }
                    }

                    const anySubHit = itemNode.children.length > 0; // sub-group means at least one child matched keyword
                    if (itemNode.children.length === 0) delete itemNode.children;
                    if (!keyword || itemHit || catHit || anySubHit) catNode.children.push(itemNode);
                });
            }

            // When searching sub-nodes (var/mod), parent item might not hit itself —
            // still include category/item if any descendant matched
            if (catNode.children.length === 0) delete catNode.children;
            if (!keyword || catHit || (catNode.children && catNode.children.length > 0)) root.children.push(catNode);
        });

        return root;
    }

    function drawItemsTreeD3(payload, validItemKeys) {
        const mainGroup = d3.select("#infim-svg-items g");
        mainGroup.selectAll("*").remove();

        const keyword = itemsSearchKeyword.trim();
        // Item-level filtering: keep only items whose compositeKey (catKey:::itemKey) is checked
        const filteredPayload = validItemKeys
            ? payload.map(cat => {
                const catKey = cat.key || '';
                const filteredItems = (cat.children || []).filter(item =>
                    validItemKeys.has(catKey + ':::' + (item.key || ''))
                );
                return filteredItems.length > 0 ? { ...cat, children: filteredItems } : null;
            }).filter(Boolean)
            : payload;

        const treeData = transformItemsDataForD3(filteredPayload, window.__infiShowItemsSubItems, keyword);
        if (!treeData.children || treeData.children.length === 0) return;

        const root = d3.hierarchy(treeData);
        const dx = 42, dy = 340;
        const tree = d3.tree().nodeSize([dx, dy]);
        tree(root);

        const matchedNodesSet = new Set();
        const pathLinkNodesSet = new Set();
        root.descendants().forEach(d => {
            if (safeCheckMatch(keyword, d.data.name, isItemsRegexMode, isItemsCaseSensitive) ||
                safeCheckMatch(keyword, d.data.id, isItemsRegexMode, isItemsCaseSensitive)) {
                matchedNodesSet.add(d);
                d.ancestors().forEach(anc => pathLinkNodesSet.add(anc));
            }
        });

        const linksData = root.links();
        const linkPathSelection = mainGroup.append("g").attr("fill", "none")
            .selectAll("path").data(linksData).join("path")
            .attr("d", d3.linkHorizontal().x(d => d.y).y(d => d.x))
            .attr("stroke", d => (keyword && pathLinkNodesSet.has(d.source) && pathLinkNodesSet.has(d.target)) ? ITEMS_LINK_COLOR : "#666666")
            .attr("stroke-opacity", d => (keyword && pathLinkNodesSet.has(d.source) && pathLinkNodesSet.has(d.target)) ? 0.95 : 0.55)
            .attr("stroke-width", d => (keyword && pathLinkNodesSet.has(d.source) && pathLinkNodesSet.has(d.target)) ? 4.5 : 1.6);

        function highlightHoverPath(targetNode) {
            const activeNodes = new Set([...targetNode.ancestors(), ...targetNode.descendants()]);
            linkPathSelection
                .attr("stroke", d => (activeNodes.has(d.source) && activeNodes.has(d.target)) ? ITEMS_LINK_COLOR :
                    (keyword && pathLinkNodesSet.has(d.source) && pathLinkNodesSet.has(d.target) ? ITEMS_LINK_COLOR : "#666666"))
                .attr("stroke-opacity", d => (activeNodes.has(d.source) && activeNodes.has(d.target)) ? 0.95 :
                    (keyword && pathLinkNodesSet.has(d.source) && pathLinkNodesSet.has(d.target) ? 0.95 : 0.55))
                .attr("stroke-width", d => (activeNodes.has(d.source) && activeNodes.has(d.target)) ? 4.5 :
                    (keyword && pathLinkNodesSet.has(d.source) && pathLinkNodesSet.has(d.target) ? 4.5 : 1.6));
        }
        function resetHoverHighlight() {
            linkPathSelection
                .attr("stroke", d => (keyword && pathLinkNodesSet.has(d.source) && pathLinkNodesSet.has(d.target)) ? ITEMS_LINK_COLOR : "#666666")
                .attr("stroke-opacity", d => (keyword && pathLinkNodesSet.has(d.source) && pathLinkNodesSet.has(d.target)) ? 0.95 : 0.55)
                .attr("stroke-width", d => (keyword && pathLinkNodesSet.has(d.source) && pathLinkNodesSet.has(d.target)) ? 4.5 : 1.6);
        }

        function isItemsTextOnRight(d) { return !d.children || d.children.length === 0; }

        const node = mainGroup.append("g").attr("stroke-linejoin", "round").attr("stroke-width", 3)
            .selectAll("g").data(root.descendants()).join("g")
            .attr("transform", d => `translate(${d.y},${d.x})`);

        node.append("circle")
            .attr("fill", d => d.children ? "#555" : "#999")
            .attr("stroke", "none")
            .attr("stroke-width", 1).attr("r", 5)
            .on("mouseover", (event, d) => { currentHoveredData = d; highlightHoverPath(d); if (!isPanelLocked) showNodeAttributesInPanel(d); })
            .on("mouseout", () => { currentHoveredData = null; if (!isPanelLocked) { resetHoverHighlight(); document.getElementById("infim-tooltip-panel").style.display = 'none'; } });

        const nameText = node.append("text")
            .attr("class", "infim-tree-name-text infim-tree-name-clickable")
            .attr("dy", "-0.3em")
            .attr("text-anchor", d => isItemsTextOnRight(d) ? "start" : "end").attr("font-weight", "bold")
            .on("mouseover", (event, d) => { currentHoveredData = d; highlightHoverPath(d); if (!isPanelLocked) showNodeAttributesInPanel(d); })
            .on("mouseout", () => { currentHoveredData = null; if (!isPanelLocked) { resetHoverHighlight(); document.getElementById("infim-tooltip-panel").style.display = 'none'; } })
            .on("click", function(event, d) {
                if (d.data.name) {
                    event.stopPropagation();
                    navigator.clipboard.writeText(d.data.name).then(() => {
                        const ce = d3.select(this); ce.selectAll("*").remove();
                        ce.append("tspan").text("✓ 复制成功 ok").attr("fill", "#52c41a").attr("font-weight", "bold");
                        setTimeout(() => renderItemsText(ce, d), 1200);
                    });
                }
            });

        function renderItemsText(selection, d) {
            selection.selectAll("*").remove();
            const typeUpper = d.data.type ? d.data.type.toUpperCase() : "";

            if (typeUpper === 'LIBRARY') selection.attr("font-size", "28px");
            else if (typeUpper === 'CATEGORY') selection.attr("font-size", "21px");
            else if (typeUpper === 'ITEM') selection.attr("font-size", "18px");
            else if (['VARGROUP', 'SETGROUP'].includes(typeUpper)) selection.attr("font-size", "15px");
            else selection.attr("font-size", "14px");

            // type prefix — skip for LIBRARY and the two group nodes
            const skipTypePrefix = typeUpper === 'LIBRARY' || typeUpper === 'VARGROUP' || typeUpper === 'SETGROUP';
            if (d.data.type && !skipTypePrefix) {
                // display nicer labels for known types
                const typeLabel = typeUpper === 'VAR' ? 'Var' : d.data.type;
                selection.append("tspan").text(`${typeLabel}: `).attr("fill", "#d946ef").attr("font-weight", "900");
            }

            const nameColor = safeCheckMatch(itemsSearchKeyword, d.data.name, isItemsRegexMode, isItemsCaseSensitive) ? "red" : "#111111";
            // group nodes rendered in muted color
            const finalColor = ['VARGROUP', 'SETGROUP'].includes(typeUpper) ? "#888" : nameColor;
            selection.append("tspan").attr("class", "infim-tspan-name").text(d.data.name).attr("fill", finalColor);

            // price for ITEM / VAR (no status)
            if (['ITEM', 'VAR', 'VARIATION'].includes(typeUpper)) {
                const raw = d.data.raw || {};
                let priceVal = raw.price != null ? raw.price : null;
                if (typeUpper === 'ITEM' && raw.min_price != null && raw.max_price != null) {
                    priceVal = raw.min_price === raw.max_price ? raw.min_price : `${raw.min_price}-${raw.max_price}`;
                }
                if (priceVal != null && priceVal !== 0 && priceVal !== '') {
                    const priceStr = typeof priceVal === 'number'
                        ? `$${priceVal % 1 === 0 ? priceVal : priceVal.toFixed(2)}`
                        : `$${priceVal}`;
                    selection.append("tspan").text(` ${priceStr}`).attr("fill", PRICE_COLOR).attr("font-weight", "700");
                }
            }

            const childCount = d.children ? d.children.length : 0;
            if (childCount > 0) selection.append("tspan").text(` [${childCount}]`).attr("fill", COUNT_COLOR).attr("font-weight", "bold");
        }

        nameText.each(function(d) {
            const typeUpper = d.data.type ? d.data.type.toUpperCase() : "";
            const p = d.data.raw && (d.data.raw.import_type || d.data.raw.platform) ? (d.data.raw.import_type || d.data.raw.platform).toUpperCase() : null;
            const hasIcon = p && p !== 'INFI' && ['SQUARE', 'HUNGERRUSH', 'TOAST', 'LIGHTSPEED'].includes(p);
            const iconSize = (typeUpper === 'LIBRARY' || typeUpper === 'CATEGORY') ? 24 : 18;
            const isRight = isItemsTextOnRight(d);
            let currentX = isRight ? 8 : -8;
            if (hasIcon && isRight) currentX += iconSize + 6;

            d3.select(this).attr("x", currentX);
            renderItemsText(d3.select(this), d);

            if (hasIcon) {
                const iconPath = getPlatformIconUrl(p);
                if (iconPath) {
                    const iconX = isRight ? 8 : (currentX - (this.getComputedTextLength() || 50) - iconSize - 4);
                    const iconY = iconSize === 24 ? -16 : -12;
                    d3.select(this.parentNode).insert("image", "text")
                        .attr("href", window.location.origin + iconPath)
                        .attr("xlink:href", window.location.origin + iconPath)
                        .attr("x", iconX).attr("y", iconY)
                        .attr("width", iconSize).attr("height", iconSize);
                }
            }
        });

        nameText.clone(true).lower().attr("class", "").attr("stroke", "rgba(255,255,255,0.85)").attr("stroke-width", 3)
            .on("click", null).on("mouseover", null).on("mouseout", null)
            .selectAll("tspan").attr("fill", null).attr("stroke", "rgba(255,255,255,0.85)");

        const idGroup = node.append("g").attr("class", "infim-id-hotspot-g")
            .on("mouseover", e => { e.stopPropagation(); if (!isPanelLocked) document.getElementById("infim-tooltip-panel").style.display = 'none'; });

        const idText = idGroup.append("text").attr("class", "infim-tree-id-text").attr("y", 16)
            .style("pointer-events", "none")
            .attr("x", d => isItemsTextOnRight(d) ? 8 : -8)
            .attr("text-anchor", d => isItemsTextOnRight(d) ? "start" : "end")
            .text(d => d.data.id && d.data.id !== "N/A" && d.data.id !== 'root' && d.data.id !== 'default' ? `ID: ${d.data.id}` : "")
            .attr("font-size", "13px")
            .attr("fill", d => safeCheckMatch(itemsSearchKeyword, d.data.id, isItemsRegexMode, isItemsCaseSensitive) ? "red" : "#666")
            .attr("font-weight", "500");

        idText.each(function(d) {
            if (!d.data.id || d.data.id === 'root' || d.data.id === 'default') return;
            const isRight = isItemsTextOnRight(d);
            const startX = isRight ? 8 : -8;
            const textLen = this.getComputedTextLength() || (d.data.id.length * 8);
            const rectX = isRight ? startX - 4 : startX - textLen - 4;
            d3.select(this.parentNode).insert("rect", "text")
                .attr("class", "id-hotspot-catcher").attr("y", 2).attr("x", rectX)
                .attr("width", textLen + 8).attr("height", 18).attr("fill", "transparent")
                .style("pointer-events", "all").style("cursor", "pointer")
                .on("mouseenter", () => { d3.select(this.parentNode).select(".infim-tree-id-text").attr("fill", "#52c41a").style("text-decoration", "underline"); })
                .on("mouseleave", () => { d3.select(this.parentNode).select(".infim-tree-id-text").attr("fill", safeCheckMatch(itemsSearchKeyword, d.data.id, isItemsRegexMode, isItemsCaseSensitive) ? "red" : "#666").style("text-decoration", "none"); })
                .on("click", function(e) {
                    e.stopPropagation();
                    navigator.clipboard.writeText(d.data.id).then(() => {
                        const tt = d3.select(this.parentNode).select(".infim-tree-id-text");
                        tt.text("✓ ID 复制成功 ok").attr("fill", "#52c41a").style("text-decoration", "none");
                        setTimeout(() => tt.text(`ID: ${d.data.id}`).attr("fill", safeCheckMatch(itemsSearchKeyword, d.data.id, isItemsRegexMode, isItemsCaseSensitive) ? "red" : "#666"), 1200);
                    });
                });

            // [显示Menu] button for Item nodes — fetch menu_names from items API
            if (d.data.type === 'Item' && d.data.id !== 'N/A') {
                const currentOffset = isRight ? (startX + textLen + 16) : (startX - textLen - 16);
                const capturedD = d;
                const btnG = d3.select(this.parentNode.parentNode).append("g").style("cursor", "pointer")
                    .on("mouseover", e => { e.stopPropagation(); if (!isPanelLocked) document.getElementById("infim-tooltip-panel").style.display = 'none'; })
                    .on("click", function(evt) {
                        evt.stopPropagation(); evt.preventDefault();
                        fetchAndShowItemMenuNames(capturedD.data.id, capturedD, d3.select(this).select(".infim-btn-action").node());
                    });
                const btnTxt = btnG.append("text").attr("class", "infim-btn-action").attr("y", 16)
                    .style("pointer-events", "none")
                    .attr("x", currentOffset).attr("text-anchor", isRight ? "start" : "end")
                    .text("[显示Menu]").style("fill", "#f59e0b").style("font-size", "13px").style("font-weight", "900");
                const btnLen = btnTxt.node().getComputedTextLength() || 72;
                const btnRectX = isRight ? currentOffset - 4 : currentOffset - btnLen - 4;
                btnG.insert("rect", "text").attr("y", 2).attr("x", btnRectX).attr("width", btnLen + 8).attr("height", 18).attr("fill", "transparent").style("pointer-events", "all");
            }
        });

        const svg = d3.select("#infim-svg-items");
        const zoom = d3.zoom().scaleExtent([0.05, 4]).on("zoom", (event) => mainGroup.attr("transform", event.transform));

        if (window.__infiItemsForceAutoCenter) {
            autoCenterTree(svg, zoom, root.descendants(), 500, 0.5);
            window.__infiItemsForceAutoCenter = false;
        } else if (window.__infiItemsDetailAutoCenter) {
            const nodeCount = root.descendants().length;
            if (window.__infiShowItemsSubItems) {
                autoCenterTree(svg, zoom, root.descendants(), 500, 0.4, 0.95);
            } else {
                const minScale = nodeCount > 220 ? 0.42 : (nodeCount > 120 ? 0.5 : 0.6);
                autoCenterTree(svg, zoom, root.descendants(), 500, minScale, 1.1);
            }
            window.__infiItemsDetailAutoCenter = false;
        } else if (keyword && matchedNodesSet.size > 0) {
            const focusNodes = root.descendants().filter(d => matchedNodesSet.has(d));
            autoCenterTree(svg, zoom, focusNodes, 500);
        } else if (window.__infiLastItemsKeyword && !keyword) {
            autoCenterTree(svg, zoom, root.descendants(), 500);
        }
        window.__infiLastItemsKeyword = keyword;
    }

    // ==========================================
    // Items Library — [显示Menu] 按钮相关函数
    // ==========================================

    function appendMenuNamesToPanel(menuNames) {
        const tooltipPanel = document.getElementById("infim-tooltip-panel");
        if (!tooltipPanel) return;

        const existing = document.getElementById("infim-menu-names-section");
        if (existing) existing.remove();

        tooltipPanel.style.display = 'block';

        const section = document.createElement('div');
        section.id = "infim-menu-names-section";
        section.style.cssText = "margin-top:12px; padding-top:10px; border-top:2px dashed rgba(245,158,11,0.5);";

        const label = document.createElement('div');
        label.style.cssText = "font-size:10px; color:#f59e0b; font-weight:900; text-transform:uppercase; letter-spacing:0.5px; margin-bottom:6px;";
        label.textContent = "📋 所属菜单 (menu_names)";
        section.appendChild(label);

        if (!menuNames || menuNames.length === 0) {
            const empty = document.createElement('div');
            empty.style.cssText = "font-size:11px; color:#aaa; font-style:italic;";
            empty.textContent = "(无所属菜单)";
            section.appendChild(empty);
        } else {
            menuNames.forEach(name => {
                const row = document.createElement('div');
                row.style.cssText = "display:flex; align-items:flex-start; justify-content:space-between; padding:4px 0; border-bottom:1px solid rgba(0,0,0,0.05); gap:6px; cursor:pointer;";

                const nameSpan = document.createElement('span');
                nameSpan.style.cssText = "font-size:11px; color:#111; font-weight:600; word-break:break-all; flex:1;";
                nameSpan.textContent = name;

                const copyBtn = document.createElement('span');
                copyBtn.style.cssText = "font-size:10px; color:#f59e0b; font-weight:800; flex-shrink:0; cursor:pointer; white-space:nowrap; padding:1px 5px; border-radius:3px; border:1px solid rgba(245,158,11,0.4);";
                copyBtn.textContent = "复制";

                const doCopy = () => {
                    navigator.clipboard.writeText(name).then(() => {
                        copyBtn.textContent = "✓";
                        copyBtn.style.color = "#52c41a";
                        copyBtn.style.borderColor = "#52c41a";
                        setTimeout(() => {
                            copyBtn.textContent = "复制";
                            copyBtn.style.color = "#f59e0b";
                            copyBtn.style.borderColor = "rgba(245,158,11,0.4)";
                        }, 1000);
                    });
                };
                row.onclick = (e) => { e.stopPropagation(); doCopy(); };
                copyBtn.onclick = (e) => { e.stopPropagation(); doCopy(); };

                row.appendChild(nameSpan);
                row.appendChild(copyBtn);
                section.appendChild(row);
            });
        }

        tooltipPanel.appendChild(section);
    }

    async function fetchAndShowItemMenuNames(itemId, nodeD, btnNode) {
        const mId = localStorage.getItem('__infi_last_detected_merchant_id');
        if (!mId) return showToast("暂未捕获到商户ID ok");

        // Lock panel and populate with current node attrs so user can see them while waiting
        isPanelLocked = true;
        const tp = document.getElementById("infim-tooltip-panel");
        const indicator = document.getElementById("infim-lock-indicator");
        if (tp) {
            tp.style.borderColor = "#52c41a";
            tp.style.boxShadow = "-4px 4px 15px rgba(82, 196, 26, 0.15)";
            tp.style.pointerEvents = "auto";
        }
        if (indicator) indicator.style.display = "block";
        if (nodeD) showNodeAttributesInPanel(nodeD);

        const el = d3.select(btnNode);
        el.text("[加载中...]");

        try {
            const finalHeaders = buildAuthHeaders();
            const url = `${window.location.origin}/merchant-portal-api/v1/merchants/${mId}/items/${itemId}`;
            const res = await originalFetch(url, { method: 'GET', headers: finalHeaders });
            const data = await res.json();

            if (data && data.code === "SUCCESS" && data.payload) {
                el.text("[显示Menu]");
                appendMenuNamesToPanel(data.payload.menu_names || []);
            } else {
                el.text("[显示Menu]");
                showToast(formatApiError(data, finalHeaders));
            }
        } catch(e) {
            el.text("[显示Menu]");
            showToast(`Network Error: ${e.message}`);
        }
    }

    // drawItemsTreeRef — category+item two-level dropdown, then draw D3 tree
    drawItemsTreeRef = function() {
        const payload = window.__infiItemsPayload;
        if (!payload || !Array.isArray(payload)) return;

        const categoryDropdown = document.getElementById("infim-items-dropdown");
        if (!categoryDropdown) return;

        // window.__infiItemsValidKeys is the authoritative checked-item set (catKey:::itemKey)
        // All onChange handlers mutate it directly so rebuild calls stay consistent.
        if (!window.__infiItemsValidKeys) window.__infiItemsValidKeys = new Set();
        const validItemKeys = window.__infiItemsValidKeys;

        // Tracks which category sections are expanded
        if (!window.__infiItemsExpandedCats) {
            window.__infiItemsExpandedCats = new Set(payload.map(c => c.key || ''));
        }
        const expandedCats = window.__infiItemsExpandedCats;

        const allCatHeaders = [];
        const allItemRefs   = [];

        const resetItemsSearchCondition = () => {
            itemsSearchKeyword = "";
            const inp = document.querySelector('#infim-items-search-control input');
            if (inp) inp.value = "";
            const clearBadge = document.querySelector("#infim-items-search-control .infim-clear-badge-btn");
            if (clearBadge) clearBadge.style.display = "none";
            const stored = window.__infiItemsCatRefs || {};
            (stored.allItemRefs || []).forEach(r => {
                r.itemCb.checked = true; validItemKeys.add(r.compositeKey);
                r.row.style.display = '';
                r.labelSpan.innerHTML = `<span>${r.itemName}</span>`;
            });
            (stored.allCatHeaders || []).forEach(h => {
                h.catBlock.style.display = '';
                h.nameSpan.innerHTML = `<span style="color:#d946ef;font-size:11px;margin-right:3px;">[Cat]</span><span>${h.catName}</span>`;
                h.catCb.checked = true; h.catCb.indeterminate = false;
                h.countSpan.textContent = `(${h.totalCount})`; h.countSpan.style.color = '#aaa';
            });
            drawItemsTreeD3(payload, validItemKeys);
        };

        if (categoryDropdown.innerHTML === '') {
            // ── First build ────────────────────────────────────────────────
            validItemKeys.clear();
            payload.forEach(category => {
                const catKey   = category.key   || '';
                const catName  = category.title || 'Unknown';
                const items    = category.children || [];

                // Category block
                const catBlock = document.createElement('div');
                catBlock.style.cssText = "border-bottom:1px solid #e8e8e8; background:#fafafa;";

                // Header row
                const catHeaderRow = document.createElement('div');
                catHeaderRow.style.cssText = "display:flex; align-items:center; padding:5px 10px; gap:6px; cursor:pointer; user-select:none;";

                const arrow = document.createElement('span');
                arrow.style.cssText = "font-size:10px; color:#aaa; width:12px; flex-shrink:0;";
                arrow.textContent = expandedCats.has(catKey) ? '▼' : '▶';

                const catCb = document.createElement('input');
                catCb.type = 'checkbox'; catCb.checked = true; catCb.style.cssText = "flex-shrink:0;";

                const nameSpan = document.createElement('span');
                nameSpan.style.cssText = "font-size:12px; font-weight:bold; color:#555; flex:1; overflow:hidden; white-space:nowrap; text-overflow:ellipsis;";
                nameSpan.innerHTML = `<span style="color:#d946ef;font-size:11px;margin-right:3px;">[Cat]</span><span>${catName}</span>`;

                const countSpan = document.createElement('span');
                countSpan.style.cssText = "font-size:11px; color:#aaa; flex-shrink:0;";
                countSpan.textContent = `(${items.length})`;

                catHeaderRow.appendChild(arrow);
                catHeaderRow.appendChild(catCb);
                catHeaderRow.appendChild(nameSpan);
                catHeaderRow.appendChild(countSpan);
                catBlock.appendChild(catHeaderRow);

                // Items container
                const itemsContainer = document.createElement('div');
                itemsContainer.style.display = expandedCats.has(catKey) ? '' : 'none';

                const catItemRefs = [];
                items.forEach(item => {
                    const itemKey      = item.key   || '';
                    const itemName     = item.title || 'Unknown';
                    const compositeKey = catKey + ':::' + itemKey;
                    validItemKeys.add(compositeKey);

                    const itemRow = document.createElement('div');
                    itemRow.style.cssText = "display:flex; align-items:center; padding:3px 10px 3px 28px; gap:6px;";

                    const itemCb = document.createElement('input');
                    itemCb.type = 'checkbox'; itemCb.checked = true; itemCb.style.cssText = "flex-shrink:0;";

                    const labelSpan = document.createElement('span');
                    labelSpan.style.cssText = "font-size:12px; color:#333; flex:1; overflow:hidden; white-space:nowrap; text-overflow:ellipsis;";
                    labelSpan.innerHTML = `<span>${itemName}</span>`;

                    itemRow.appendChild(itemCb);
                    itemRow.appendChild(labelSpan);
                    itemsContainer.appendChild(itemRow);

                    const ref = { catKey, catName, itemKey, itemName, compositeKey, itemCb, labelSpan, row: itemRow };
                    catItemRefs.push(ref);
                    allItemRefs.push(ref);

                    itemCb.onchange = () => {
                        if (itemCb.checked) validItemKeys.add(compositeKey);
                        else validItemKeys.delete(compositeKey);
                        const checkedCnt = catItemRefs.filter(r => r.itemCb.checked).length;
                        catCb.indeterminate = checkedCnt > 0 && checkedCnt < items.length;
                        catCb.checked = checkedCnt === items.length;
                        countSpan.textContent = checkedCnt < items.length ? `(${checkedCnt}/${items.length})` : `(${items.length})`;
                        countSpan.style.color = checkedCnt < items.length ? '#fa8c16' : '#aaa';
                        drawItemsTreeD3(payload, validItemKeys);
                    };
                });

                catBlock.appendChild(itemsContainer);
                categoryDropdown.appendChild(catBlock);

                // Toggle expand/collapse on header click (not on the checkbox itself)
                catHeaderRow.addEventListener('click', e => {
                    if (e.target === catCb) return;
                    const isExpanded = itemsContainer.style.display !== 'none';
                    if (isExpanded) { itemsContainer.style.display = 'none'; arrow.textContent = '▶'; expandedCats.delete(catKey); }
                    else            { itemsContainer.style.display = '';     arrow.textContent = '▼'; expandedCats.add(catKey); }
                });

                // Category checkbox: bulk toggle all its items
                catCb.onchange = () => {
                    catItemRefs.forEach(r => {
                        r.itemCb.checked = catCb.checked;
                        if (catCb.checked) validItemKeys.add(r.compositeKey);
                        else               validItemKeys.delete(r.compositeKey);
                    });
                    catCb.indeterminate = false;
                    const checkedCnt = catCb.checked ? items.length : 0;
                    countSpan.textContent = catCb.checked ? `(${items.length})` : `(0/${items.length})`;
                    countSpan.style.color = catCb.checked ? '#aaa' : '#fa8c16';
                    drawItemsTreeD3(payload, validItemKeys);
                };

                const catHeaderRef = { catKey, catName, catCb, catBlock, itemsContainer, arrow, nameSpan, countSpan, totalCount: items.length, itemRefs: catItemRefs };
                allCatHeaders.push(catHeaderRef);
            });

            window.__infiItemsCatRefs = { allCatHeaders, allItemRefs };

        } else {
            // ── Subsequent call — reuse existing DOM, reconstruct state ───
            const stored = window.__infiItemsCatRefs || {};
            (stored.allCatHeaders || []).forEach(h => allCatHeaders.push(h));
            (stored.allItemRefs   || []).forEach(r => { allItemRefs.push(r); if (r.itemCb.checked) validItemKeys.add(r.compositeKey); else validItemKeys.delete(r.compositeKey); });
        }

        const keyword = itemsSearchKeyword.trim();
        let matchCount = 0;
        if (keyword) {
            allCatHeaders.forEach(catHeader => {
                const catHit = safeCheckMatch(keyword, catHeader.catName, isItemsRegexMode, isItemsCaseSensitive) ||
                               safeCheckMatch(keyword, catHeader.catKey,  isItemsRegexMode, isItemsCaseSensitive);
                let catHasItemHit = false;

                catHeader.itemRefs.forEach(r => {
                    const itemHit = safeCheckMatch(keyword, r.itemName, isItemsRegexMode, isItemsCaseSensitive) ||
                                    safeCheckMatch(keyword, r.itemKey,  isItemsRegexMode, isItemsCaseSensitive);
                    if (catHit || itemHit) {
                        r.row.style.display = '';
                        r.labelSpan.innerHTML = `<span style="color:red;font-weight:bold;">${r.itemName}</span>`;
                        r.itemCb.checked = true; validItemKeys.add(r.compositeKey);
                        if (itemHit) { catHasItemHit = true; matchCount++; }
                    } else {
                        r.row.style.display = 'none';
                    }
                });

                if (catHit || catHasItemHit) {
                    catHeader.catBlock.style.display = '';
                    catHeader.itemsContainer.style.display = '';
                    catHeader.arrow.textContent = '▼';
                    if (catHit) {
                        catHeader.nameSpan.innerHTML = `<span style="color:#d946ef;font-size:11px;margin-right:3px;">[Cat]</span><span style="color:red;font-weight:bold;">${catHeader.catName}</span>`;
                        matchCount++;
                        catHeader.itemRefs.forEach(r => { r.row.style.display = ''; r.labelSpan.innerHTML = `<span>${r.itemName}</span>`; });
                    } else {
                        catHeader.nameSpan.innerHTML = `<span style="color:#d946ef;font-size:11px;margin-right:3px;">[Cat]</span><span>${catHeader.catName}</span>`;
                    }
                } else {
                    catHeader.catBlock.style.display = 'none';
                }
            });

            const clearBadge = document.querySelector("#infim-items-search-control .infim-clear-badge-btn");
            if (clearBadge) { clearBadge.innerHTML = `${matchCount}条结果 <span style="font-size:10px;margin-left:2px;">✕</span>`; clearBadge.style.display = "flex"; }
        } else {
            allCatHeaders.forEach(catHeader => {
                catHeader.catBlock.style.display = '';
                catHeader.nameSpan.innerHTML = `<span style="color:#d946ef;font-size:11px;margin-right:3px;">[Cat]</span><span>${catHeader.catName}</span>`;
                catHeader.itemRefs.forEach(r => { r.row.style.display = ''; r.labelSpan.innerHTML = `<span>${r.itemName}</span>`; });
            });
            const clearBadge = document.querySelector("#infim-items-search-control .infim-clear-badge-btn");
            if (clearBadge) clearBadge.style.display = "none";
        }

        const clearBadge = document.querySelector("#infim-items-search-control .infim-clear-badge-btn");
        if (clearBadge) clearBadge.onclick = (e) => { e.stopPropagation(); resetItemsSearchCondition(); };

        drawItemsTreeD3(payload, validItemKeys);
    };

    // ==========================================
    // 9. Items Library 数据获取（两个接口）
    // ==========================================
    async function fetchItemsLibraryData(btnElement) {
        const mId = localStorage.getItem('__infi_last_detected_merchant_id');
        const host = window.location.origin;
        if (!mId) return showToast("暂未捕获到商户ID，请先打开商户页面 ok");

        const btn = d3.select(btnElement);
        if (btnElement) { btn.style("transform", "rotate(360deg)").style("transition", "transform 0.6s ease"); }

        const finalHeaders = buildAuthHeaders();

        try {
            const [productsRes, modSetsRes] = await Promise.all([
                originalFetch(`${host}/merchant-portal-api/v1/merchants/${mId}/get-products`, { method: 'GET', headers: finalHeaders }),
                originalFetch(`${host}/merchant-portal-api/v1/merchants/${mId}/modifiers-sets`, { method: 'GET', headers: finalHeaders }),
            ]);
            const [productsData, modSetsData] = await Promise.all([productsRes.json(), modSetsRes.json()]);

            if (modSetsData && modSetsData.code === "SUCCESS") handleModifierSetsIntercept(modSetsData.payload);
            if (productsData && productsData.code === "SUCCESS") {
                window.__infiItemsPayload = productsData.payload;
                window.__infiItemsLoaded = true;
                const dropdown = document.getElementById("infim-items-dropdown");
                if (dropdown) dropdown.innerHTML = '';
                window.__infiItemsCatRefs = null;
                window.__infiItemsValidKeys = null;
                window.__infiItemsExpandedCats = null;
                window.__infiItemsForceAutoCenter = true;
                if (drawItemsTreeRef) drawItemsTreeRef();
            } else {
                showToast(formatApiError(productsData, finalHeaders));
            }
        } catch(e) {
            showToast(`Network Error: ${e.message}`);
        }
    }

})();