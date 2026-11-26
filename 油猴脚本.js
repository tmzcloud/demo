// ==UserScript==
// @name         Infi Menu & Merchant Locations SVG Tree (V12.2 面板号+Menu嵌套)
// @namespace    http://tampermonkey.net/
// @version      12.2
// @description  面板空心页码1/2/3；Menu有嵌套的Mod可点加载；细节/嵌套防OOM。
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

    // 启动时清掉旧版塞进 localStorage 的整棵 Menu 树（易超配额）
    try {
        const _oldMenu = localStorage.getItem('__infi_last_menu_payload');
        if (_oldMenu && _oldMenu.length > 8000) {
            let meta = { menu_id: '', menu_name: '', _metaOnly: true };
            try {
                const _p = JSON.parse(_oldMenu);
                meta.menu_id = _p.menu_id || '';
                meta.menu_name = _p.menu_name || '';
            } catch (_) {}
            localStorage.removeItem('__infi_last_menu_payload');
            try { localStorage.setItem('__infi_last_menu_payload', JSON.stringify(meta)); } catch (_) {}
        }
    } catch (e) {
        try { localStorage.removeItem('__infi_last_menu_payload'); } catch (_) {}
    }

    window.__infiMerchantPayload = null;
    window.__infiMenuPayload = null;

    let leftSearchKeyword = "";
    let isLeftRegexMode = true;
    let isLeftCaseSensitive = false;

    let rightSearchKeyword = "";
    let isRightRegexMode = true;
    let isRightCaseSensitive = false;
    window.__infiShowSubItems = false;
    window.__infiMenuNestExpanded = new Set(); // Menu 面板：已展开嵌套的 nestKey 集合

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
    window.__infiModifierSetsMap = {};      // modifier_set_id → import_type (兼容旧逻辑)
    window.__infiModifierSetsById = {};    // modifier_set_id → 完整 modifiers-sets 元素（含 nested_tree）
    // 嵌套 Set 里「无下级」的 Mod 常只有名字；用全局价目表从各接口能见到的对象补 price
    window.__infiModPriceById = {};
    window.__infiModPriceByName = {};
    window.__infiItemsLoaded = false;
    window.__infiModifierSetsLoaded = false;
    window.__infiShowItemsSubItems = false;
    window.__infiItemsForceAutoCenter = false;
    window.__infiItemsDetailAutoCenter = false;
    window.__infiItemsNestExpanded = new Set(); // 第三页：嵌套仅按钮展开
    window.__infiItemsSkipAutoCenter = false;
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

                    // 仅恢复完整 menu 树；_metaOnly 只有 menu_id，不能当树画
                    if (!window.__infiMenuPayload) {
                        const cached = readCachedMenuMeta();
                        if (cached && !cached._metaOnly && cached.group) window.__infiMenuPayload = cached;
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
                    const cached = readCachedMenuMeta();
                    if (cached && !cached._metaOnly && cached.group) window.__infiMenuPayload = cached;
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

    // 用各面板顶部 ↻ 按钮的转圈 UI 表示全局加载（引用计数，可嵌套）
    let __infiGlobalLoadingCount = 0;
    function syncGlobalLoadingUI() {
        const on = __infiGlobalLoadingCount > 0;
        document.querySelectorAll('.infim-refresh-btn').forEach(btn => {
            btn.classList.toggle('infim-global-loading', on);
            if (!on) {
                btn.style.transform = '';
                btn.style.transition = '';
            }
        });
    }
    function beginGlobalLoading() {
        __infiGlobalLoadingCount++;
        syncGlobalLoadingUI();
    }
    function endGlobalLoading() {
        __infiGlobalLoadingCount = Math.max(0, __infiGlobalLoadingCount - 1);
        syncGlobalLoadingUI();
    }
    async function withGlobalLoading(promiseOrFn) {
        beginGlobalLoading();
        try {
            return typeof promiseOrFn === 'function' ? await promiseOrFn() : await promiseOrFn;
        } finally {
            endGlobalLoading();
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

    function safeLocalSet(key, value) {
        try {
            localStorage.setItem(key, value);
            return true;
        } catch (e) {
            try {
                // 配额满：丢掉大体量缓存后再试一次
                localStorage.removeItem('__infi_last_menu_payload');
                localStorage.removeItem('__infi_last_merchant_payload');
                localStorage.setItem(key, value);
                return true;
            } catch (e2) {
                console.warn('[Infi] localStorage quota, skip', key, e2 && e2.message);
                return false;
            }
        }
    }

    // Menu 整树很大，禁止写入 localStorage（会超 5MB 配额）。只记 menu_id 供刷新。
    function persistMenuPayloadMeta(payload) {
        if (!payload || !payload.menu_id) return;
        safeLocalSet('__infi_last_menu_payload', JSON.stringify({
            menu_id: payload.menu_id,
            menu_name: payload.menu_name || '',
            _metaOnly: true
        }));
    }

    function readCachedMenuMeta() {
        try {
            const raw = localStorage.getItem('__infi_last_menu_payload');
            if (!raw) return null;
            const parsed = JSON.parse(raw);
            if (!parsed || !parsed.menu_id) return null;
            return parsed;
        } catch (e) { return null; }
    }

    // Merchant 缓存去掉门店已加载菜单，避免连带超配额
    function persistMerchantPayload(payload) {
        if (!payload) return;
        try {
            const slim = {
                merchant_id: payload.merchant_id,
                merchant_name: payload.merchant_name,
                raw_merchant: payload.raw_merchant,
                locations: (payload.locations || []).map(loc => {
                    const copy = { ...loc };
                    delete copy._loadedMenus;
                    copy._hasLoadedMenus = false;
                    delete copy._expandedByUser;
                    return copy;
                })
            };
            safeLocalSet('__infi_last_merchant_payload', JSON.stringify(slim));
        } catch (e) {
            console.warn('[Infi] persistMerchantPayload failed', e && e.message);
        }
    }

    function wipeMerchantCache() {
        console.log("🧹 [Infi Merchant] 检测到登录或商户变更，执行无条件强制清场 ok");
        window.__infiMerchantPayload = null;
        window.__infiMenuPayload = null;
        window.__infiItemsPayload = null;
        window.__infiModifierSetsMap = {};
        window.__infiModifierSetsById = {};
        window.__infiModNestIndex = {};
        window.__infiModPriceById = {};
        window.__infiModPriceByName = {};
        window.__infiItemsLoaded = false;
        window.__infiModifierSetsLoaded = false;
        window.__infiItemsCatRefs = null;
        window.__infiItemsValidKeys = null;
        window.__infiItemsExpandedCats = null;
        window.__infiMenuNestExpanded = new Set();
        window.__infiItemsNestExpanded = new Set();
        window.__infiVariationPlatformMap = {};
        window.__infiCurrentLocationId = null;
        window.__infiMenuToLocationMap = {};
        window.__infiMenuNameToIdMap = {};
        localStorage.removeItem('__infi_last_merchant_payload');
        localStorage.removeItem('__infi_last_menu_payload');
        safeLocalSet('__infi_last_active_view', 'left');
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

    function rememberModPrice(mod) {
        if (!mod || typeof mod !== 'object') return;
        const price = mod.price;
        if (price == null || price === '') return;
        const id = mod.modifier_id != null ? String(mod.modifier_id) : '';
        const name = mod.name != null ? String(mod.name) : '';
        if (id) window.__infiModPriceById[id] = price;
        if (name) window.__infiModPriceByName[name] = price;
    }

    function harvestModPricesFromMods(mods, depth) {
        depth = depth | 0;
        if (depth > 24 || !Array.isArray(mods)) return;
        mods.forEach(m => {
            if (m == null || typeof m === 'string') return;
            rememberModPrice(m);
            if (Array.isArray(m.children)) {
                m.children.forEach(cs => {
                    if (!cs || typeof cs !== 'object') return;
                    harvestModPricesFromMods(cs.modifiers, depth + 1);
                });
            }
        });
    }

    function harvestModPricesFromModifierSetsPayload(payload) {
        if (!Array.isArray(payload)) return;
        payload.forEach(ms => {
            if (!ms) return;
            if (Array.isArray(ms.modifiers)) {
                ms.modifiers.forEach(m => { if (m && typeof m === 'object') rememberModPrice(m); });
            }
            if (ms.nested_tree && Array.isArray(ms.nested_tree.modifiers)) {
                harvestModPricesFromMods(ms.nested_tree.modifiers, 0);
            }
        });
    }

    function harvestModPricesFromProductsPayload(payload) {
        if (!Array.isArray(payload)) return;
        payload.forEach(cat => {
            (cat.children || []).forEach(item => {
                (item.modifier_set || []).forEach(ms => {
                    (ms.modifiers || []).forEach(m => {
                        if (m && typeof m === 'object') rememberModPrice(m);
                    });
                });
            });
        });
    }

    function harvestModPricesFromMenuPayload(menuPayload) {
        if (!menuPayload) return;
        const list = menuPayload.menu_modifier_set_list;
        if (Array.isArray(list)) {
            list.forEach(ms => {
                (ms && ms.modifiers || []).forEach(m => {
                    if (m && typeof m === 'object') rememberModPrice(m);
                });
            });
        }
        (menuPayload.group || []).forEach(g => {
            (g.item_or_combo || []).forEach(item => {
                (item.modifier_set || []).forEach(ms => {
                    (ms.modifiers || []).forEach(m => {
                        if (m && typeof m === 'object') rememberModPrice(m);
                    });
                });
            });
        });
    }

    function lookupModPrice(modId, modName) {
        if (modId && window.__infiModPriceById[String(modId)] != null) {
            return window.__infiModPriceById[String(modId)];
        }
        if (modName && window.__infiModPriceByName[String(modName)] != null) {
            return window.__infiModPriceByName[String(modName)];
        }
        return null;
    }

    function handlePassiveMenuIntercept(dataPayload) {
        if (!dataPayload || !dataPayload.menu_id) return;
        window.__infiMenuPayload = dataPayload;
        persistMenuPayloadMeta(dataPayload);
        harvestModPricesFromMenuPayload(dataPayload);
        safeLocalSet('__infi_last_active_view', 'right');

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
        harvestModPricesFromProductsPayload(payload);
        const overlay = document.getElementById("infi-merchant-overlay");
        if (overlay && overlay.style.display !== 'none' && drawItemsTreeRef) {
            window.__infiItemsForceAutoCenter = true;
            drawItemsTreeRef();
        }
    }

    function rebuildModNestIndex() {
        // msId → { byId, byName } → children[]；一次建好，细节展开时 O(1) 查有无嵌套
        const index = {};
        const byIdAll = window.__infiModifierSetsById || {};
        Object.keys(byIdAll).forEach(msId => {
            const full = byIdAll[msId];
            const mods = full && full.nested_tree && Array.isArray(full.nested_tree.modifiers)
                ? full.nested_tree.modifiers : null;
            if (!mods || !mods.length) return;
            const byId = {};
            const byName = {};
            for (let i = 0; i < mods.length; i++) {
                const m = mods[i];
                if (!m || !Array.isArray(m.children) || !m.children.length) continue;
                if (m.modifier_id != null) byId[String(m.modifier_id)] = m.children;
                if (m.name != null) byName[String(m.name)] = m.children;
            }
            index[String(msId)] = { byId, byName };
        });
        window.__infiModNestIndex = index;
    }

    function handleModifierSetsIntercept(payload) {
        const map = {};
        const byId = {};
        if (Array.isArray(payload)) {
            payload.forEach(ms => {
                if (!ms || !ms.modifier_set_id) return;
                map[ms.modifier_set_id] = ms.import_type || '';
                byId[ms.modifier_set_id] = ms;
            });
        }
        window.__infiModifierSetsMap = map;
        window.__infiModifierSetsById = byId;
        window.__infiModifierSetsLoaded = true;
        rebuildModNestIndex();
        harvestModPricesFromModifierSetsPayload(payload);
        // nested_tree 到位后重绘：Items 开细节 / Menu 开细节（嵌套按钮依赖）
        const overlay = document.getElementById("infi-merchant-overlay");
        if (overlay && overlay.style.display !== 'none') {
            if (window.__infiShowItemsSubItems && drawItemsTreeRef) drawItemsTreeRef();
            if (window.__infiShowSubItems && drawMenuTreeRef) drawMenuTreeRef();
        }
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
        persistMerchantPayload(payload);

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
        // Build menu_id → location_id；menu_name → [{menuId, locationId}]（同名多店不互相覆盖）
        if (Array.isArray(menusPayload)) {
            if (!window.__infiMenuToLocationMap) window.__infiMenuToLocationMap = {};
            if (!window.__infiMenuNameToIdMap) window.__infiMenuNameToIdMap = {};
            menusPayload.forEach(m => {
                if (!m) return;
                if (m.menu_id) window.__infiMenuToLocationMap[m.menu_id] = locationId;
                const mName = m.menu_name || m.name || '';
                if (m.menu_id && mName) {
                    const arr = Array.isArray(window.__infiMenuNameToIdMap[mName])
                        ? window.__infiMenuNameToIdMap[mName]
                        : (window.__infiMenuNameToIdMap[mName] ? [{ menuId: window.__infiMenuNameToIdMap[mName], locationId: null }] : []);
                    const exists = arr.some(x => String(x.menuId) === String(m.menu_id) && String(x.locationId || '') === String(locationId || ''));
                    if (!exists) arr.push({ menuId: m.menu_id, locationId });
                    window.__infiMenuNameToIdMap[mName] = arr;
                }
            });
        }
        if (found) {
            persistMerchantPayload(window.__infiMerchantPayload);
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
                persistMenuPayloadMeta(data.payload);
                harvestModPricesFromMenuPayload(data.payload);

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
            const cachedMenu = readCachedMenuMeta() || {};
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
                persistMenuPayloadMeta(data.payload);
                harvestModPricesFromMenuPayload(data.payload);

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
            persistMerchantPayload(window.__infiMerchantPayload);
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

    // | 分条件后至少有一段非空才算有效搜索；单独 "|" / "||" 视为无关键字
    function effectiveSearchParts(keyword) {
        if (!keyword) return [];
        return String(keyword).split('|').map(p => p.trim()).filter(p => p.length > 0);
    }
    function hasEffectiveSearchKeyword(keyword) {
        return effectiveSearchParts(keyword).length > 0;
    }

    function safeCheckMatch(keyword, targetStr, isRegex, isCaseS) {
        if (!keyword || targetStr == null) return false;
        const s = String(targetStr);
        // | 表示多条件 OR。空段（单独 "|"、"a|"、"|b"、"||"）一律丢弃，
        // 禁止空分支在正则里匹配任意字符串导致全树命中卡死。
        const parts = effectiveSearchParts(keyword);
        if (parts.length === 0) return false;

        return parts.some(part => {
            if (isRegex) {
                try {
                    if (new RegExp(part, isCaseS ? "" : "i").test(s)) return true;
                } catch (e) { /* invalid regex → fall through to substring */ }
                const needle = isCaseS ? part : part.toLowerCase();
                const haystack = isCaseS ? s : s.toLowerCase();
                return haystack.includes(needle);
            }
            const needle = isCaseS ? part : part.toLowerCase();
            const haystack = isCaseS ? s : s.toLowerCase();
            return haystack === needle;
        });
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

    // 防止全量 nested_tree 图展开导致浏览器 OOM（沿当前路径递归）
    const MAX_MOD_NEST_DEPTH = 20;

    function menuNestKey(msId, modId, modName) {
        return String(msId || '') + '::' + String(modId || modName || '');
    }

    // 从 modifiers-sets.nested_tree 取某个 Mod 的嵌套子 Set 列表；无嵌套返回 null（优先走索引）
    function findModNestChildSets(msId, modId, modName) {
        if (!msId) return null;
        const idx = (window.__infiModNestIndex || {})[String(msId)];
        if (idx) {
            const kids = (modId && idx.byId[String(modId)])
                || (modName && idx.byName[String(modName)])
                || null;
            return kids && kids.length ? kids : null;
        }
        const full = (window.__infiModifierSetsById || {})[msId];
        if (!full || !full.nested_tree || !Array.isArray(full.nested_tree.modifiers)) return null;
        const hit = full.nested_tree.modifiers.find(m => m && (
            (modId && String(m.modifier_id || '') === String(modId)) ||
            (modName && String(m.name || '') === String(modName))
        ));
        if (hit && Array.isArray(hit.children) && hit.children.length) return hit.children;
        return null;
    }

    // 第一层 Mod 列表：只用顶层 modifiers，避免 buildCompleteModEntries 扫整棵 nested_tree
    function listFirstLayerModsForSet(ms, full) {
        const from = (arr) => (Array.isArray(arr) ? arr : []).map(m =>
            typeof m === 'string' ? { name: m } : m
        ).filter(Boolean);
        if (ms && Array.isArray(ms.modifiers) && ms.modifiers.length) return from(ms.modifiers);
        if (full && Array.isArray(full.modifiers) && full.modifiers.length) return from(full.modifiers);
        if (full && Array.isArray(full.modifier_names) && full.modifier_names.length) return from(full.modifier_names);
        // 最后才退化到 nested_tree 顶层（只取本层，不 merge）
        if (full && full.nested_tree && Array.isArray(full.nested_tree.modifiers)) {
            return full.nested_tree.modifiers.map(m => m && ({
                name: m.name,
                modifier_id: m.modifier_id,
                price: m.price
            })).filter(Boolean);
        }
        return [];
    }

    // 递归判断 nested_tree / 子 Set 片段是否命中关键字（用于搜索自动展开、下拉勾选）
    function nestedFragmentMatchesKeyword(fragment, keyword, isRegex, isCaseS, depth, seen) {
        if (!hasEffectiveSearchKeyword(keyword) || !fragment || typeof fragment !== 'object') return false;
        depth = depth | 0;
        if (depth > MAX_MOD_NEST_DEPTH) return false;
        seen = seen || new Set();

        const msId = String(fragment.modifier_set_id || '');
        const seenKey = msId || ('name:' + String(fragment.display_name || fragment.set_name || '').trim());
        if (seenKey && seen.has(seenKey)) return false;
        const nextSeen = new Set(seen);
        if (seenKey) nextSeen.add(seenKey);

        const full = msId ? ((window.__infiModifierSetsById || {})[msId] || {}) : {};
        const fragHasMods = Array.isArray(fragment.modifiers) && fragment.modifiers.length > 0;
        const walkTree = fragHasMods
            ? fragment
            : ((msId && full.nested_tree && typeof full.nested_tree === 'object') ? full.nested_tree : fragment);
        const msName = walkTree.display_name || walkTree.set_name || fragment.display_name || fragment.set_name
            || full.display_name || full.set_name || '';
        if (safeCheckMatch(keyword, msName, isRegex, isCaseS) || safeCheckMatch(keyword, msId, isRegex, isCaseS)) return true;

        let mods;
        if (msId) {
            mods = buildCompleteModEntries(msId, walkTree);
        } else {
            mods = (Array.isArray(walkTree.modifiers) ? walkTree.modifiers : []).map(m =>
                typeof m === 'string' ? { name: m, children: [] } : m
            );
        }
        for (let i = 0; i < mods.length; i++) {
            const mod = mods[i];
            if (!mod) continue;
            const modName = typeof mod === 'string' ? mod : String(mod.name || '');
            const modId = typeof mod === 'string' ? '' : String(mod.modifier_id || '');
            if (safeCheckMatch(keyword, modName, isRegex, isCaseS) || safeCheckMatch(keyword, modId, isRegex, isCaseS)) return true;

            let childSets = (typeof mod === 'object' && Array.isArray(mod.children) && mod.children.length) ? mod.children : [];
            if (!childSets.length && walkTree && Array.isArray(walkTree.modifiers)) {
                const hit = walkTree.modifiers.find(m => m && (
                    (modId && String(m.modifier_id || '') === modId) ||
                    (modName && String(m.name || '') === modName)
                ));
                if (hit && Array.isArray(hit.children) && hit.children.length) childSets = hit.children;
            }
            for (let j = 0; j < childSets.length; j++) {
                const childSet = childSets[j];
                if (!childSet || typeof childSet !== 'object') continue;
                const childId = resolveChildModifierSetId(childSet);
                const childKey = childId || ('name:' + String(childSet.display_name || childSet.set_name || '').trim());
                if (childKey && nextSeen.has(childKey)) continue;
                let nextFragment = childSet;
                const childHasMods = Array.isArray(childSet.modifiers) && childSet.modifiers.length > 0;
                if (!childHasMods && childId) {
                    const childFull = (window.__infiModifierSetsById || {})[childId];
                    if (childFull && childFull.nested_tree && typeof childFull.nested_tree === 'object') {
                        nextFragment = childFull.nested_tree;
                    }
                }
                if (nestedFragmentMatchesKeyword(nextFragment, keyword, isRegex, isCaseS, depth + 1, nextSeen)) return true;
            }
        }
        return false;
    }

    function nestChildSetsMatchKeyword(childSets, keyword, isRegex, isCaseS, parentMsId) {
        if (!hasEffectiveSearchKeyword(keyword) || !childSets || !childSets.length) return false;
        for (let i = 0; i < childSets.length; i++) {
            const cs = childSets[i];
            if (!cs || typeof cs !== 'object') continue;
            const seen = new Set();
            if (parentMsId) seen.add(String(parentMsId));
            if (nestedFragmentMatchesKeyword(cs, keyword, isRegex, isCaseS, 0, seen)) return true;
        }
        return false;
    }

    // Item / Menu 顶层 modifier_set 列表是否在嵌套层命中关键字
    function modifierSetsHaveNestedKeywordMatch(msList, keyword, isRegex, isCaseS) {
        if (!hasEffectiveSearchKeyword(keyword) || !Array.isArray(msList)) return false;
        for (let i = 0; i < msList.length; i++) {
            const ms = msList[i];
            if (!ms) continue;
            const msId = ms.modifier_set_id || '';
            if (safeCheckMatch(keyword, ms.name || ms.display_name, isRegex, isCaseS)
                || safeCheckMatch(keyword, msId, isRegex, isCaseS)) return true;
            const mods = Array.isArray(ms.modifiers) ? ms.modifiers : [];
            for (let j = 0; j < mods.length; j++) {
                const m = mods[j];
                const mName = typeof m === 'string' ? m : (m && m.name);
                const mId = typeof m === 'string' ? '' : (m && m.modifier_id);
                if (safeCheckMatch(keyword, mName, isRegex, isCaseS) || safeCheckMatch(keyword, mId, isRegex, isCaseS)) return true;
                const nestKids = findModNestChildSets(msId, mId, mName);
                if (nestKids && nestChildSetsMatchKeyword(nestKids, keyword, isRegex, isCaseS, msId)) return true;
            }
            const full = msId ? ((window.__infiModifierSetsById || {})[msId] || null) : null;
            if (full && full.nested_tree && nestedFragmentMatchesKeyword(full.nested_tree, keyword, isRegex, isCaseS, 0, new Set())) {
                return true;
            }
        }
        return false;
    }

    // Menu.menu_modifier_set_list → 按 setId / modId|name 索引，给嵌套节点补 status/price
    function indexMenuModifierSetList(menuPayload) {
        const bySetId = {};
        const list = (menuPayload && Array.isArray(menuPayload.menu_modifier_set_list))
            ? menuPayload.menu_modifier_set_list
            : [];
        list.forEach(ms => {
            if (!ms || !ms.modifier_set_id) return;
            const modsById = {};
            const modsByName = {};
            (Array.isArray(ms.modifiers) ? ms.modifiers : []).forEach(m => {
                if (!m) return;
                if (m.modifier_id != null) modsById[String(m.modifier_id)] = m;
                if (m.name != null) modsByName[String(m.name)] = m;
            });
            bySetId[String(ms.modifier_set_id)] = { set: ms, modsById, modsByName };
        });
        return bySetId;
    }

    function enrichMenuNestTreeFromList(node, menuMsIndex, parentSetId) {
        if (!node || !menuMsIndex) return;
        if (node.type === 'Set' || node.type === 'SetRef') {
            const sid = String(node.id || '');
            const entry = menuMsIndex[sid];
            if (entry && entry.set && node.type === 'Set') {
                const s = entry.set;
                node.name = s.display_name || s.name || node.name;
                node.raw = {
                    ...(node.raw || {}),
                    is_active: s.is_active,
                    platform: s.platform || (node.raw && node.raw.platform) || '',
                    name: s.name,
                    display_name: s.display_name,
                    minimum_quantity: s.minimum_quantity,
                    maximum_quantity: s.maximum_quantity
                };
            }
            (node.children || []).forEach(ch => enrichMenuNestTreeFromList(ch, menuMsIndex, sid));
            return;
        }
        if (node.type === 'Mod') {
            const entry = menuMsIndex[String(parentSetId || '')];
            if (entry) {
                const m = (node.id && entry.modsById[String(node.id)])
                    || (node.name && entry.modsByName[String(node.name)])
                    || null;
                if (m) {
                    const keep = {
                        hasNesting: node.raw && node.raw.hasNesting,
                        nestKey: node.raw && node.raw.nestKey,
                        nestExpanded: node.raw && node.raw.nestExpanded,
                        parentSetId: node.raw && node.raw.parentSetId,
                        cycleToSetId: node.raw && node.raw.cycleToSetId
                    };
                    node.raw = { ...(node.raw || {}), ...m, ...keep, catalog_type: 'MODIFIER' };
                }
            }
            (node.children || []).forEach(ch => {
                const nextParent = (ch.type === 'Set' || ch.type === 'SetRef') ? ch.id : parentSetId;
                enrichMenuNestTreeFromList(ch, menuMsIndex, nextParent);
            });
        }
    }

    function buildMenuModNestChildren(msId, childSets, menuMsIndex, keyword, ancestorHit) {
        if (!childSets || !childSets.length) return [];
        const kw = hasEffectiveSearchKeyword(keyword) ? keyword : '';
        const out = [];
        childSets.forEach(cs => {
            if (!cs || typeof cs !== 'object') return;
            // 每个子 Set 独立路径 seen，避免兄弟分支互相误判成环
            const seen = new Set();
            if (msId) seen.add(String(msId));
            // 有关键字时按命中过滤；无关键字则 ancestorHit=true 展开完整嵌套
            const node = buildNestedModifierSetNode(
                cs,
                kw,
                kw ? !!ancestorHit : true,
                seen,
                0,
                isRightRegexMode,
                isRightCaseSensitive
            );
            if (node && node.type !== 'SetRef') {
                enrichMenuNestTreeFromList(node, menuMsIndex, node.id);
                out.push(node);
            }
        });
        return out;
    }

    async function ensureModifierSetsLoadedForMenu() {
        if (window.__infiModifierSetsLoaded) return true;
        const mId = localStorage.getItem('__infi_last_detected_merchant_id');
        if (!mId) return false;
        const finalHeaders = buildAuthHeaders();
        try {
            const res = await originalFetch(
                `${window.location.origin}/merchant-portal-api/v1/merchants/${mId}/modifiers-sets`,
                { method: 'GET', headers: finalHeaders }
            );
            const data = await res.json();
            if (data && data.code === "SUCCESS") {
                handleModifierSetsIntercept(data.payload);
                return true;
            }
        } catch (e) { /* ignore */ }
        return false;
    }

    function toggleMenuModNest(nestKey) {
        if (!window.__infiMenuNestExpanded) window.__infiMenuNestExpanded = new Set();
        const expanded = window.__infiMenuNestExpanded.has(nestKey);
        // 展开/收起嵌套时保持当前镜头，不要 autoCenter 往回拉
        window.__infiMenuSkipAutoCenter = true;
        if (expanded) {
            window.__infiMenuNestExpanded.delete(nestKey);
            if (drawMenuTreeRef) drawMenuTreeRef();
            return;
        }
        (async () => {
            await ensureModifierSetsLoadedForMenu();
            window.__infiMenuNestExpanded.add(nestKey);
            window.__infiMenuSkipAutoCenter = true;
            if (drawMenuTreeRef) drawMenuTreeRef();
        })();
    }

    function transformMenuDataForD3(payload, validGroupIds, validItemIds, showSubItems, keyword) {
        if (!hasEffectiveSearchKeyword(keyword)) keyword = '';
        const menuMsIndex = indexMenuModifierSetList(payload);

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
                    // 优先用 menu_modifier_set_list 补 Set 层信息
                    const listEntry = menuMsIndex[String(ms.modifier_set_id || '')];
                    const listSet = listEntry && listEntry.set ? listEntry.set : null;
                    let msNode = {
                        type: 'Set',
                        name: (listSet && (listSet.display_name || listSet.name)) || ms.name,
                        id: ms.modifier_set_id,
                        children: [],
                        raw: { ...ms, ...(listSet || {}), platform: msPlatform || (listSet && listSet.platform) || ms.platform || '' }
                    };

                    // modifiers：item.modifier_set 为主；缺字段时用 menu_modifier_set_list 补 status/price
                    const rawMods = Array.isArray(ms.modifiers) && ms.modifiers.length
                        ? ms.modifiers
                        : (listSet && Array.isArray(listSet.modifiers) ? listSet.modifiers : []);
                    if (rawMods.length) {
                        rawMods.forEach(m => {
                            const base = typeof m === 'string' ? { name: m } : m;
                            const listMod = listEntry
                                ? ((base.modifier_id && listEntry.modsById[String(base.modifier_id)])
                                    || (base.name && listEntry.modsByName[String(base.name)])
                                    || null)
                                : null;
                            const merged = listMod ? { ...listMod, ...base, ...listMod } : base;
                            // list 优先 status/price（菜单态）
                            if (listMod) {
                                if (listMod.status != null) merged.status = listMod.status;
                                if (listMod.price != null) merged.price = listMod.price;
                                if (listMod.is_active != null) merged.is_active = listMod.is_active;
                                if (listMod.is_client_visible != null) merged.is_client_visible = listMod.is_client_visible;
                                if (listMod.price_format_display != null) merged.price_format_display = listMod.price_format_display;
                                if (listMod.platform != null) merged.platform = listMod.platform;
                            }
                            let mHit = safeCheckMatch(keyword, merged.name, isRightRegexMode, isRightCaseSensitive) || safeCheckMatch(keyword, merged.modifier_id, isRightRegexMode, isRightCaseSensitive);
                            const nestKids = findModNestChildSets(ms.modifier_set_id, merged.modifier_id, merged.name);
                            const nestKey = menuNestKey(ms.modifier_set_id, merged.modifier_id, merged.name);
                            // 搜索命中嵌套：展开命中路径并写入集合（可点收起）；无搜索仍须点按钮
                            const nestHit = !!(keyword && nestKids && nestChildSetsMatchKeyword(
                                nestKids, keyword, isRightRegexMode, isRightCaseSensitive, ms.modifier_set_id
                            ));
                            if (nestHit) {
                                if (!window.__infiMenuNestExpanded) window.__infiMenuNestExpanded = new Set();
                                window.__infiMenuNestExpanded.add(nestKey);
                            }
                            const nestExpanded = !!(nestKids && window.__infiMenuNestExpanded && window.__infiMenuNestExpanded.has(nestKey));
                            if (!keyword || mHit || nestHit || msHit || itemMatchedSelf || groupMatchedSelf) {
                                const modNode = {
                                    type: 'Mod',
                                    name: merged.name,
                                    id: merged.modifier_id,
                                    children: [],
                                    raw: {
                                        ...merged,
                                        hasNesting: !!nestKids,
                                        nestKey,
                                        parentSetId: ms.modifier_set_id || '',
                                        nestExpanded
                                    }
                                };
                                if (nestExpanded) {
                                    // 已展开（按钮/搜索写入）：完整加载子树，避免搜索词把深层裁空导致「点了没内容」
                                    buildMenuModNestChildren(
                                        ms.modifier_set_id,
                                        nestKids,
                                        menuMsIndex,
                                        '',
                                        true
                                    ).forEach(n => modNode.children.push(n));
                                }
                                if (modNode.children.length === 0) delete modNode.children;
                                msNode.children.push(modNode);
                                if (mHit || nestHit) anySubHit = true;
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
            safeLocalSet('__infi_last_active_view', 'right');
            if (drawMenuTreeRef) drawMenuTreeRef();
            else if (typeof updateMenuEmptyHint === 'function') updateMenuEmptyHint();
        } else if (direction === 'items') {
            slider.style.transform = 'translateX(-200vw)';
            safeLocalSet('__infi_last_active_view', 'items');
            if (!window.__infiItemsLoaded) {
                fetchItemsLibraryData(null);
            } else if (drawItemsTreeRef) {
                drawItemsTreeRef();
            }
        } else {
            slider.style.transform = 'translateX(0)';
            safeLocalSet('__infi_last_active_view', 'left');
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
            /* 全局加载态：用顶部 ↻ 转圈表示（不依赖是否点了刷新） */
            .infim-refresh-btn.infim-global-loading {
                animation: infimSpinAni 0.75s linear infinite;
                border-color: #52c41a;
                color: #52c41a;
                background: #f6ffed;
            }
            @keyframes infimSpinAni {
                from { transform: rotate(0deg); }
                to { transform: rotate(360deg); }
            }

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

            .infim-btn-action { font-size: 15px !important; fill: #9ca3af !important; font-weight: 800 !important; cursor: pointer !important; transition: fill 0.2s ease-in-out; }
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

            .infi-panel-num {
                position: absolute; bottom: 16px; right: 24px; z-index: 2;
                font-size: 56px; font-weight: 900; line-height: 1;
                font-family: Impact, Haettenschweiler, "Arial Black", sans-serif;
                color: transparent; -webkit-text-stroke: 2px rgba(0,0,0,0.16);
                user-select: none; pointer-events: none; letter-spacing: -1px;
            }
            .infi-panel-empty-hint {
                position: absolute; inset: 0; z-index: 1;
                display: flex; align-items: center; justify-content: center;
                font-size: 48px; font-weight: 900; line-height: 1.2;
                font-family: Impact, Haettenschweiler, "Arial Black", sans-serif;
                color: transparent; -webkit-text-stroke: 2px rgba(0,0,0,0.14);
                text-align: center; user-select: none; pointer-events: none;
                letter-spacing: 1px; padding: 24px;
            }
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
        const leftPanelNum = document.createElement('div'); leftPanelNum.className = "infi-panel-num"; leftPanelNum.textContent = "1"; leftView.appendChild(leftPanelNum);
        const leftTitle = document.createElement('div'); leftTitle.className = "infi-view-title"; leftTitle.innerText = "MERCHANT LOCATION TREE"; leftView.appendChild(leftTitle);

        const rightView = document.createElement('div');
        rightView.className = "infi-view-panel"; rightView.id = "infi-right-view";
        const leftNavBtn = document.createElement('div'); leftNavBtn.className = "infi-nav-btn"; leftNavBtn.id = "infi-nav-left"; leftNavBtn.innerHTML = "〈";
        leftNavBtn.onclick = () => slideView('left');
        rightView.appendChild(leftNavBtn);
        const rightToItemsNavBtn = document.createElement('div'); rightToItemsNavBtn.className = "infi-nav-btn"; rightToItemsNavBtn.id = "infi-nav-right2"; rightToItemsNavBtn.innerHTML = "〉";
        rightToItemsNavBtn.onclick = () => slideView('items');
        rightView.appendChild(rightToItemsNavBtn);
        const rightPanelNum = document.createElement('div'); rightPanelNum.className = "infi-panel-num"; rightPanelNum.textContent = "2"; rightView.appendChild(rightPanelNum);
        const rightEmptyHint = document.createElement('div');
        rightEmptyHint.className = "infi-panel-empty-hint";
        rightEmptyHint.id = "infim-menu-empty-hint";
        rightEmptyHint.textContent = "No menu selected...";
        rightView.appendChild(rightEmptyHint);
        const rightTitle = document.createElement('div'); rightTitle.className = "infi-view-title"; rightTitle.innerText = "MENU DETAIL TREE"; rightView.appendChild(rightTitle);

        const itemsView = document.createElement('div');
        itemsView.className = "infi-view-panel"; itemsView.id = "infi-items-view";
        const itemsLeftNavBtn = document.createElement('div'); itemsLeftNavBtn.className = "infi-nav-btn"; itemsLeftNavBtn.id = "infi-nav-left2"; itemsLeftNavBtn.innerHTML = "〈";
        itemsLeftNavBtn.onclick = () => slideView('right');
        itemsView.appendChild(itemsLeftNavBtn);
        const itemsPanelNum = document.createElement('div'); itemsPanelNum.className = "infi-panel-num"; itemsPanelNum.textContent = "3"; itemsView.appendChild(itemsPanelNum);
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
        rSearchInput.oninput = () => {
            rightSearchKeyword = rSearchInput.value.trim();
            // 嵌套搜索依赖 modifiers-sets.nested_tree：有关键字且开着细节时先拉齐再绘
            if (rightSearchKeyword && window.__infiShowSubItems) {
                ensureModifierSetsLoadedForMenu().then(() => { if (drawMenuTreeRef) drawMenuTreeRef(); });
            } else if (drawMenuTreeRef) {
                drawMenuTreeRef();
            }
        };
        rRegexBtn.title = isRightRegexMode ? "模糊搜索(含子串/正则) — 点击切换精确匹配" : "精确匹配 — 点击切换模糊搜索";
        rRegexBtn.onclick = (e) => {
            e.stopPropagation(); isRightRegexMode = !isRightRegexMode;
            rRegexBtn.classList.toggle("active", isRightRegexMode);
            rRegexBtn.title = isRightRegexMode ? "模糊搜索(含子串/正则) — 点击切换精确匹配" : "精确匹配 — 点击切换模糊搜索";
            rSearchInput.placeholder = isRightRegexMode ? "输入字符模糊过滤Item/Combo..." : "输入字符精确匹配Item/Combo(完全相等)...";
            if(drawMenuTreeRef) drawMenuTreeRef();
        };
        rCaseBtn.onclick = (e) => { e.stopPropagation(); isRightCaseSensitive = !isRightCaseSensitive; rCaseBtn.classList.toggle("active", isRightCaseSensitive); if(drawMenuTreeRef) drawMenuTreeRef(); };
        rDetailToggleBtn.onclick = (e) => {
            e.stopPropagation();
            window.__infiShowSubItems = !window.__infiShowSubItems;
            rDetailToggleBtn.classList.toggle("active", window.__infiShowSubItems);
            if (!window.__infiShowSubItems) {
                window.__infiMenuNestExpanded = new Set();
            }
            if (window.__infiShowSubItems) {
                // 只拉 nested_tree 元数据；真正嵌套仍要点「嵌套」按钮
                ensureModifierSetsLoadedForMenu().then(() => { if (drawMenuTreeRef) drawMenuTreeRef(); });
            } else if (drawMenuTreeRef) {
                drawMenuTreeRef();
            }
        };

        iSearchInput.onfocus = () => { if (!iSearchInput.value.trim()) { itemsSearchKeyword = ""; if (drawItemsTreeRef) drawItemsTreeRef(); } iTreeBodyContainer.style.display = "flex"; iSearchInput.style.borderColor = "#52c41a"; };
        iSearchInput.oninput = () => {
            itemsSearchKeyword = iSearchInput.value.trim();
            // 手动清空搜索框时同样关掉细节，避免全量嵌套撑爆
            if (!itemsSearchKeyword && window.__infiShowItemsSubItems) {
                window.__infiShowItemsSubItems = false;
                window.__infiItemsNestExpanded = new Set();
                iDetailToggleBtn.classList.remove('active');
            }
            // 嵌套搜索依赖 modifiers-sets：有关键字且开着细节时先拉齐再绘
            if (itemsSearchKeyword && window.__infiShowItemsSubItems) {
                ensureItemsDetailData(null);
            } else if (drawItemsTreeRef) {
                drawItemsTreeRef();
            }
        };
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
            if (!window.__infiShowItemsSubItems) {
                window.__infiItemsNestExpanded = new Set();
            }
            if (window.__infiShowItemsSubItems) {
                // 先让 UI 响应，再异步拉数据/重绘，避免点击瞬间主线程卡死
                beginGlobalLoading();
                setTimeout(() => {
                    Promise.resolve(ensureItemsDetailData(iDetailToggleBtn))
                        .finally(() => { endGlobalLoading(); });
                }, 0);
            } else if (drawItemsTreeRef) {
                beginGlobalLoading();
                setTimeout(() => {
                    try { drawItemsTreeRef(); } finally { endGlobalLoading(); }
                }, 0);
            }
        };
        iToggleAllBtn.onclick = function(e) {
            e.stopPropagation();
            // 先展开下拉；未构建过时先建 checkbox DOM（原先依赖 focus 才建）
            iTreeBodyContainer.style.display = "flex";
            iSearchInput.style.borderColor = "#52c41a";
            // 防止上次异常中断后 __infiItemsDrawing 卡死导致后续都不绘
            window.__infiItemsDrawing = false;
            window.__infiItemsDrawPending = null;
            if (!window.__infiItemsCatRefs || !Array.isArray(window.__infiItemsCatRefs.allItemRefs)
                || window.__infiItemsCatRefs.allItemRefs.length === 0) {
                if (drawItemsTreeRef) drawItemsTreeRef();
            }
            const stored = window.__infiItemsCatRefs;
            if (!stored || !Array.isArray(stored.allItemRefs) || stored.allItemRefs.length === 0) return;
            const allItemRefs = stored.allItemRefs;
            const allCatHeaders = stored.allCatHeaders || [];
            const visibleItems = allItemRefs.filter(r => r.row && r.row.style.display !== 'none');
            const targets = visibleItems.length > 0 ? visibleItems : allItemRefs;
            const allChecked = targets.every(r => r.itemCb && r.itemCb.checked);
            const next = !allChecked;
            if (!window.__infiItemsValidKeys) window.__infiItemsValidKeys = new Set();
            const validItemKeys = window.__infiItemsValidKeys;
            // 禁止逐个 dispatch change：每个 change 都会整树重绘，200+ Item 会卡死
            window.__infiItemsBulkToggle = true;
            try {
                targets.forEach(r => {
                    r.itemCb.checked = next;
                    if (next) validItemKeys.add(r.compositeKey);
                    else validItemKeys.delete(r.compositeKey);
                });
                allCatHeaders.forEach(h => {
                    const refs = h.itemRefs || [];
                    if (!refs.length) return;
                    const cnt = refs.filter(r => r.itemCb && r.itemCb.checked).length;
                    h.catCb.indeterminate = cnt > 0 && cnt < refs.length;
                    h.catCb.checked = cnt === refs.length;
                    if (h.countSpan) {
                        h.countSpan.textContent = cnt < refs.length ? `(${cnt}/${refs.length})` : `(${refs.length})`;
                        h.countSpan.style.color = cnt < refs.length ? '#fa8c16' : '#aaa';
                    }
                });
            } finally {
                window.__infiItemsBulkToggle = false;
            }
            const payload = window.__infiItemsPayload;
            if (payload) drawItemsTreeD3(payload, validItemKeys);
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

                if (typeUpper === 'MERCHANT') selection.attr("font-size", "30px").attr("font-weight", "900");
                else if (typeUpper === 'LOCATION' || typeUpper === 'MENU') selection.attr("font-size", "23px").attr("font-weight", "bold");
                else selection.attr("font-size", "16px").attr("font-weight", "bold");

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
                .attr("font-size", "15px")
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
                        .text(btnStr).style("fill", "#52c41a").style("font-size", "15px").style("font-weight", "900");

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
                        .text("[➜ Load Tree]").style("fill", "#52c41a").style("font-size", "15px").style("font-weight", "900");

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

    function updateMenuEmptyHint() {
        const hint = document.getElementById("infim-menu-empty-hint");
        if (!hint) return;
        const payload = window.__infiMenuPayload;
        const hasMenu = !!(payload && payload.menu_id && Array.isArray(payload.group));
        hint.style.display = hasMenu ? "none" : "flex";
    }

    drawMenuTreeRef = function() {
        const payload = window.__infiMenuPayload;
        updateMenuEmptyHint();
        if (!payload) {
            try { d3.select("#infim-svg-right g").selectAll("*").remove(); } catch (_) {}
            return;
        }

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
                    if (item.modifier_set && Array.isArray(item.modifier_set)) {
                        if (modifierSetsHaveNestedKeywordMatch(item.modifier_set, rawInput, isRightRegexMode, isRightCaseSensitive)) {
                            isDeepMatched = true;
                        }
                    }

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

        // 有展开嵌套时拉大行列距，避免子 Set 挤在一起
        const hasExpandedNest = !!(window.__infiMenuNestExpanded && window.__infiMenuNestExpanded.size > 0);
        const dx = hasExpandedNest ? 64 : 42;
        const dy = hasExpandedNest ? 420 : 340;
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
                if (t === 'SETREF') return '#fdf4ff';
                if (['ITEM', 'COMBO', 'COMBOITEM', 'MOD', 'VAR', 'SET'].includes(t)) {
                    let st = d.data.raw && d.data.raw.status ? String(d.data.raw.status).toUpperCase() : "";
                    if (st === "AVAILABLE") return "#52c41a";
                    if (st === "HIDDEN") return "#f4f4f4";
                }
                return d.children ? "#555" : "#999";
            })
            .attr("stroke", d => {
                let t = d.data.type ? d.data.type.toUpperCase() : "";
                if (t === 'SETREF') return '#d946ef';
                if (['ITEM', 'COMBO', 'COMBOITEM', 'MOD', 'VAR', 'SET'].includes(t)) {
                    let st = d.data.raw && d.data.raw.status ? String(d.data.raw.status).toUpperCase() : "";
                    if (st === "HIDDEN") return "#ccc";
                }
                return "none";
            })
            .attr("stroke-width", d => (d.data.type && d.data.type.toUpperCase() === 'SETREF') ? 1.6 : 1)
            .attr("stroke-dasharray", d => (d.data.type && d.data.type.toUpperCase() === 'SETREF') ? '3,2' : null)
            .attr("r", 5)
            .on("mouseover", (event, d) => { currentHoveredData = d; highlightHoverPath(d); if (!isPanelLocked) showNodeAttributesInPanel(d); })
            .on("mouseout", () => {
                currentHoveredData = null;
                resetHoverHighlight();
                if (!isPanelLocked) document.getElementById("infim-tooltip-panel").style.display = 'none';
            });

        const nameText = node.append("text")
            .attr("class", "infim-tree-name-text infim-tree-name-clickable")
            .attr("dy", "-0.3em")
            .attr("text-anchor", d => isRightTreeTextOnRight(d) ? "start" : "end").attr("font-weight", "bold")
            .on("mouseover", (event, d) => { currentHoveredData = d; highlightHoverPath(d); if (!isPanelLocked) showNodeAttributesInPanel(d); })
            .on("mouseout", () => {
                currentHoveredData = null;
                resetHoverHighlight();
                if (!isPanelLocked) document.getElementById("infim-tooltip-panel").style.display = 'none';
            })
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

            if (typeUpper === 'MENU' || typeUpper === 'MENU ROOT' || typeUpper === 'MERCHANT') selection.attr("font-size", "30px").attr("font-weight", "900");
            else if (typeUpper === 'GROUP' || typeUpper === 'LOCATION') selection.attr("font-size", "23px").attr("font-weight", "bold");
            else selection.attr("font-size", "16px").attr("font-weight", "bold");

            if (d.data.type && d.data.type !== 'Type') {
                const typeLabel = typeUpper === 'SETREF' ? 'Set↻' : d.data.type;
                selection.append("tspan").text(`${typeLabel}: `).attr("fill", "#d946ef").attr("font-weight", "900");
            }

            selection.append("tspan").attr("class", "infim-tspan-name")
                .text(d.data.name).attr("fill", safeCheckMatch(rightSearchKeyword, d.data.name, isRightRegexMode, isRightCaseSensitive) ? "red" : "#111111");

            if (['ITEM', 'COMBO', 'COMBOITEM', 'MOD', 'VAR', 'COMBOSET'].includes(typeUpper)) {
                const priceStr = getNodePrice(d.data.raw, typeUpper);
                if (priceStr !== null) {
                    selection.append("tspan").text(` ${priceStr}`).attr("fill", PRICE_COLOR).attr("font-weight", "700");
                }
            }

            if (typeUpper === 'SETREF' || (typeUpper === 'MOD' && d.data.raw && d.data.raw.cycleToSetId)) {
                selection.append("tspan").text(" ↻环回").attr("fill", "#d946ef").attr("font-weight", "700");
            }

            const childCount = d.children ? d.children.length : 0;
            const isLoc = typeUpper === 'LOCATION';
            const isLoaded = isLoc && d.data.raw && d.data.raw._hasLoadedMenus;

            if (typeUpper !== 'SETREF' && (childCount > 0 || isLoaded)) {
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

            // Menu 根下：location name : location id（灰、比 Menu 小一号=28px）
            if (typeUpper === 'MENU' || typeUpper === 'MENU ROOT') {
                const locInfo = resolveLocationLabelForMenu(d.data.id);
                if (locInfo) {
                    d3.select(this.parentNode).append("text")
                        .attr("class", "infim-menu-loc-text")
                        .attr("x", currentX)
                        .attr("y", 22)
                        .attr("text-anchor", isRight ? "start" : "end")
                        .attr("font-size", "28px")
                        .attr("font-weight", "600")
                        .attr("fill", "#9ca3af")
                        .style("pointer-events", "none")
                        .text(`${locInfo.locName} : ${locInfo.locId}`);
                }
            }

            // Menu：有嵌套的 Mod — 醒目色块但扁平（矮、无描边），垂直中心对齐名称文字
            if (typeUpper === 'MOD' && d.data.raw && d.data.raw.hasNesting && d.data.raw.nestKey) {
                const nestKey = d.data.raw.nestKey;
                const nestOn = !!(window.__infiMenuNestExpanded && window.__infiMenuNestExpanded.has(nestKey));
                const label = nestOn ? '收起嵌套' : '嵌套 ▸';
                const nameLen = this.getComputedTextLength() || 50;
                const btnG = d3.select(this.parentNode).append('g')
                    .attr('class', 'infim-menu-nest-btn')
                    .style('cursor', 'pointer')
                    .on('mouseover', e => { e.stopPropagation(); if (!isPanelLocked) document.getElementById('infim-tooltip-panel').style.display = 'none'; })
                    .on('click', function(evt) {
                        evt.stopPropagation();
                        evt.preventDefault();
                        toggleMenuModNest(nestKey);
                    });
                const probe = btnG.append('text')
                    .attr('x', 0).attr('y', 0)
                    .style('font-size', '13px').style('font-weight', '700')
                    .style('pointer-events', 'none')
                    .attr('opacity', 0)
                    .text(label);
                const tw = (probe.node().getComputedTextLength() || 48) + 12;
                probe.remove();
                const bh = 16; // 扁平：矮一点
                // 名称文字 dy=-0.3em、约16px → 视觉中心约在 -7；按钮中心对齐该处
                const textCenterY = -7;
                const bx = nestOn ? 14 : (isRight ? (currentX + nameLen + 8) : 14);
                const by = textCenterY - bh / 2;
                // 扁平色块 + 细外边框，保持醒目但不厚重
                btnG.append('rect')
                    .attr('x', bx).attr('y', by)
                    .attr('width', tw).attr('height', bh)
                    .attr('rx', 3).attr('ry', 3)
                    .attr('fill', nestOn ? '#8b5cf6' : '#ff0055')
                    .attr('stroke', nestOn ? '#5b21b6' : '#be123c')
                    .attr('stroke-width', 1.25);
                btnG.append('text')
                    .attr('x', bx + tw / 2)
                    .attr('y', textCenterY)
                    .attr('dominant-baseline', 'central')
                    .attr('text-anchor', 'middle')
                    .style('font-size', '13px').style('font-weight', '700')
                    .style('pointer-events', 'none')
                    .attr('fill', '#fff')
                    .text(label);
            }
        });

        nameText.clone(true).lower().attr("class", "").attr("stroke", "rgba(255,255,255,0.85)").attr("stroke-width", 3).on("click", null).on("mouseover", null).on("mouseout", null).selectAll("tspan").attr("fill", null).attr("stroke", "rgba(255,255,255,0.85)");

        const idGroup = node.append("g").attr("class", "infim-id-hotspot-g")
            .on("mouseover", e => { e.stopPropagation(); if (!isPanelLocked) document.getElementById("infim-tooltip-panel").style.display = 'none'; });

        // 保留阻挡穿透魔法；Menu 根有 location 行时 ID 下移，避免叠字
        const idText = idGroup.append("text").attr("class", "infim-tree-id-text")
            .attr("y", d => {
                const t = d.data.type ? d.data.type.toUpperCase() : "";
                if ((t === 'MENU' || t === 'MENU ROOT') && resolveLocationLabelForMenu(d.data.id)) return 44;
                return 16;
            })
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
            .attr("font-size", "15px")
            .attr("fill", d => safeCheckMatch(rightSearchKeyword, d.data.id, isRightRegexMode, isRightCaseSensitive) ? "red" : "#666")
            .attr("font-weight", "500");

        idText.each(function(d) {
            if (!d.data.id || d.data.id === "N/A") return;
            let typeUpper = d.data.type ? d.data.type.toUpperCase() : "";
            let p = d.data.raw && d.data.raw.platform ? d.data.raw.platform.toUpperCase() : null;
            let hasIcon = p && p !== 'INFI' && ['SQUARE', 'HUNGERRUSH', 'TOAST', 'LIGHTSPEED'].includes(p);
            let isRight = isRightTreeTextOnRight(d);
            const hasLocLine = (typeUpper === 'MENU' || typeUpper === 'MENU ROOT') && !!resolveLocationLabelForMenu(d.data.id);
            const idY = hasLocLine ? 44 : 16;

            let startX = isRight ? 8 : -8;
            if (hasIcon && isRight) {
                let iconSize = (typeUpper === 'MENU' || typeUpper === 'MENU ROOT') ? 24 : 18;
                startX += iconSize + 6;
            }

            let textLen = this.getComputedTextLength() || (d.data.id.length * 8);
            let rectX = isRight ? startX - 4 : startX - textLen - 4;

            d3.select(this.parentNode).insert("rect", "text")
                .attr("class", "id-hotspot-catcher")
                .attr("y", idY - 14).attr("x", rectX)
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

        // 第一层 Mod 后方紫色虚线竖线：分隔后续嵌套 Set（与面板3一致）
        function isMenuFirstLayerMod(d) {
            if (!d || !d.data || d.data.type !== 'Mod') return false;
            if (!d.parent || !d.parent.data || d.parent.data.type !== 'Set') return false;
            const gp = d.parent.parent;
            if (!gp || !gp.data) return false;
            // Item → Type(Modifier Sets) → Set → Mod，或 Var → Set → Mod
            if (gp.data.type === 'Type' && gp.data.name === 'Modifier Sets') return true;
            if (gp.data.type === 'Var') return true;
            return false;
        }
        const menuFirstLayerMods = root.descendants().filter(isMenuFirstLayerMod);
        const menuNestedAfterFirst = root.descendants().filter(d =>
            d.parent && isMenuFirstLayerMod(d.parent)
            && (d.data.type === 'Set' || d.data.type === 'SetRef')
        );
        if (menuFirstLayerMods.length > 0 && menuNestedAfterFirst.length > 0) {
            const xLine = d3.mean(menuFirstLayerMods, d => d.y) + dy * 0.48;
            const y0 = d3.min(menuNestedAfterFirst.concat(menuFirstLayerMods), d => d.x) - 28;
            const y1 = d3.max(menuNestedAfterFirst.concat(menuFirstLayerMods), d => d.x) + 28;
            mainGroup.append('line')
                .attr('class', 'infim-nest-sep')
                .attr('x1', xLine).attr('x2', xLine)
                .attr('y1', y0).attr('y2', y1)
                .attr('stroke', '#d946ef')
                .attr('stroke-dasharray', '7,5')
                .attr('stroke-width', 3.2)
                .attr('stroke-opacity', 0.95);
        }

        // 环回弧线（与面板3同逻辑）：Mod.cycleToSetId / SetRef → 本链路祖先 Set
        try {
            const svgRoot = d3.select('#infim-svg-right');
            if (svgRoot.select('defs').empty()) svgRoot.insert('defs', ':first-child');
            if (svgRoot.select('#infim-menu-cycle-arrow').empty()) {
                svgRoot.select('defs').append('marker')
                    .attr('id', 'infim-menu-cycle-arrow')
                    .attr('viewBox', '0 0 10 10')
                    .attr('refX', 9).attr('refY', 5)
                    .attr('markerWidth', 7).attr('markerHeight', 7)
                    .attr('orient', 'auto-start-reverse')
                    .append('path').attr('d', 'M 0 0 L 10 5 L 0 10 z').attr('fill', '#d946ef');
            }
        } catch (_) {}
        function findMenuAncestorSetById(node, setId) {
            const want = String(setId || '');
            if (!want || !node) return null;
            let p = node.parent;
            while (p) {
                if (p.data && p.data.type === 'Set' && String(p.data.id || '') === want) return p;
                p = p.parent;
            }
            return null;
        }
        const menuCycleLinks = [];
        root.descendants().forEach(d => {
            if (d.data.type === 'Mod' && d.data.raw && d.data.raw.cycleToSetId) {
                const target = findMenuAncestorSetById(d, d.data.raw.cycleToSetId);
                if (target) menuCycleLinks.push({ source: d, target });
                else delete d.data.raw.cycleToSetId;
                return;
            }
            if (d.data.type === 'SetRef') {
                const refId = (d.data.raw && d.data.raw.refSetId) || d.data.id;
                const target = findMenuAncestorSetById(d, refId);
                if (target) menuCycleLinks.push({ source: d, target });
            }
        });
        mainGroup.append('g').attr('class', 'infim-cycle-links').attr('fill', 'none')
            .selectAll('path').data(menuCycleLinks).join('path')
            .attr('d', d => {
                const x1 = d.source.y, y1 = d.source.x, x2 = d.target.y, y2 = d.target.x;
                const sweep = (y1 < y2 ? -1 : 1) * (36 + Math.abs(y1 - y2) * 0.15);
                const mx = (x1 + x2) / 2;
                const my = (y1 + y2) / 2 + sweep;
                return 'M' + x1 + ',' + y1 + ' Q' + mx + ',' + my + ' ' + x2 + ',' + y2;
            })
            .attr('stroke', '#d946ef')
            .attr('stroke-dasharray', '6,4')
            .attr('stroke-width', 2)
            .attr('stroke-opacity', 0.9)
            .attr('marker-end', 'url(#infim-menu-cycle-arrow)');

        try {
            mainGroup.select('g.infim-cycle-links').raise();
            mainGroup.selectAll('g.infim-id-hotspot-g').raise();
            mainGroup.selectAll('text.infim-tree-name-text').raise();
            mainGroup.selectAll('g.infim-menu-nest-btn').raise();
            mainGroup.selectAll('circle').raise();
        } catch (_) {}

        const svg = d3.select("#infim-svg-right");
        const zoom = d3.zoom().scaleExtent([0.05, 4]).on("zoom", (event) => mainGroup.attr("transform", event.transform));

        if (window.__infiMenuSkipAutoCenter) {
            // 嵌套展开/收起：保持当前镜头，不往回拉
            window.__infiMenuSkipAutoCenter = false;
            const prevTransform = d3.zoomTransform(svg.node());
            svg.call(zoom).call(zoom.transform, prevTransform);
            mainGroup.attr("transform", prevTransform);
        } else if (window.__infiForceMenuAutoCenter) {
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

    // nested_tree builder: Set -> Mod -> (Set -> Mod -> ...)
    // nested_tree 往往只含「有嵌套」的 modifier；完整列表从 modifiers-sets 补齐
    // 环：最下层 Mod 的 children 指向已出现的 Set 时，不展开，画回环到祖先 Set

    function indexNestedModEntries(modsArr) {
        const byId = new Map();
        const byName = new Map();
        (Array.isArray(modsArr) ? modsArr : []).forEach(m => {
            if (m == null) return;
            if (typeof m === 'string') {
                if (!byName.has(m)) byName.set(m, { name: m, children: [] });
                return;
            }
            const id = m.modifier_id != null ? String(m.modifier_id) : '';
            const name = m.name != null ? String(m.name) : '';
            if (id) byId.set(id, m);
            if (name && !byName.has(name)) byName.set(name, m);
        });
        return { byId, byName };
    }

    function buildCompleteModEntries(msId, fragmentTree) {
        const full = (window.__infiModifierSetsById || {})[msId] || {};
        const fragMods = (fragmentTree && Array.isArray(fragmentTree.modifiers)) ? fragmentTree.modifiers : [];
        const fullTreeMods = (full.nested_tree && Array.isArray(full.nested_tree.modifiers)) ? full.nested_tree.modifiers : [];
        const fragIdx = indexNestedModEntries(fragMods);
        const fullIdx = indexNestedModEntries(fullTreeMods);

        let ordered = [];
        // 优先 list 顶层 modifiers（含无嵌套的项）；nested_tree 往往只有「有嵌套」的子集
        if (Array.isArray(full.modifiers) && full.modifiers.length > 0) {
            ordered = full.modifiers.map(x => (typeof x === 'string' ? { name: x } : x));
        } else if (Array.isArray(full.modifier_names) && full.modifier_names.length > 0) {
            ordered = full.modifier_names.map(x => (typeof x === 'string' ? { name: x } : x));
        } else if (fullTreeMods.length > 0) {
            ordered = fullTreeMods.slice();
        } else {
            ordered = fragMods.slice();
        }

        // 补上 fragment / fullTree 里有、但 ordered 还没有的（按 id/name）
        const seenKeys = new Set();
        const mark = (m) => {
            if (!m) return;
            if (typeof m === 'string') { seenKeys.add('n:' + m); return; }
            if (m.modifier_id) seenKeys.add('i:' + String(m.modifier_id));
            if (m.name) seenKeys.add('n:' + String(m.name));
        };
        ordered.forEach(mark);
        const appendIfNew = (m) => {
            if (m == null) return;
            if (typeof m === 'string') {
                if (seenKeys.has('n:' + m)) return;
                ordered.push({ name: m }); mark(m); return;
            }
            const id = m.modifier_id != null ? String(m.modifier_id) : '';
            const name = m.name != null ? String(m.name) : '';
            if ((id && seenKeys.has('i:' + id)) || (name && seenKeys.has('n:' + name))) return;
            ordered.push(m); mark(m);
        };
        fragMods.forEach(appendIfNew);
        fullTreeMods.forEach(appendIfNew);

        return ordered.map(entry => {
            const name = typeof entry === 'string' ? entry : String(entry.name || '');
            const id = typeof entry === 'string' ? '' : String(entry.modifier_id || '');
            const fromFrag = (id && fragIdx.byId.get(id)) || (name && fragIdx.byName.get(name)) || null;
            const fromFull = (id && fullIdx.byId.get(id)) || (name && fullIdx.byName.get(name)) || null;
            const rich = fromFrag || fromFull || (typeof entry === 'object' ? entry : { name });
            const children = (fromFrag && Array.isArray(fromFrag.children) && fromFrag.children.length)
                ? fromFrag.children
                : ((fromFull && Array.isArray(fromFull.children) && fromFull.children.length) ? fromFull.children : (rich.children || []));
            const modId = rich.modifier_id || id || '';
            const modName = rich.name || name || 'Unknown';
            // nested_tree 常缺「无下级」Mod 的 price；从全局价目表补
            let price = rich.price;
            if (price == null || price === '') {
                const mapped = lookupModPrice(modId, modName);
                if (mapped != null) price = mapped;
            }
            return {
                ...rich,
                name: modName,
                modifier_id: modId,
                price,
                title_l2: rich.title_l2 || '',
                children: Array.isArray(children) ? children : []
            };
        });
    }

    function resolveChildModifierSetId(childSet) {
        if (!childSet || typeof childSet !== 'object') return '';
        const id = String(childSet.modifier_set_id || '');
        if (id) return id;
        const name = String(childSet.display_name || childSet.set_name || '').trim();
        if (!name) return '';
        const all = window.__infiModifierSetsById || {};
        for (const k of Object.keys(all)) {
            const v = all[k] || {};
            if (String(v.display_name || '') === name || String(v.set_name || '') === name) return String(k);
        }
        return '';
    }

    // 沿当前路径递归嵌套 Set→Mod（不把子 Set 整图替换进来）
    function buildNestedModifierSetNode(fragmentTree, keyword, ancestorHit, seenIds, depth, isRegex, isCaseS) {
        if (!fragmentTree || typeof fragmentTree !== 'object') return null;
        depth = depth | 0;
        if (depth > MAX_MOD_NEST_DEPTH) return null;
        if (typeof isRegex !== 'boolean') isRegex = isItemsRegexMode;
        if (typeof isCaseS !== 'boolean') isCaseS = isItemsCaseSensitive;

        const msId = String(fragmentTree.modifier_set_id || '');
        const seen = seenIds || new Set();
        const full = msId ? ((window.__infiModifierSetsById || {})[msId] || {}) : {};
        const seenKey = msId || ('name:' + String(fragmentTree.display_name || fragmentTree.set_name || '').trim());

        if (seenKey && seen.has(seenKey)) {
            const msName = fragmentTree.display_name || fragmentTree.set_name || full.display_name || full.set_name || 'Unknown';
            return {
                type: 'SetRef',
                name: msName,
                id: msId || seenKey,
                raw: { isCycleRef: true, refSetId: msId || seenKey, modifier_set_id: msId, display_name: msName, catalog_type: 'MODIFIER_SET' }
            };
        }

        const nextSeen = new Set(seen);
        if (seenKey) nextSeen.add(seenKey);

        // 优先走当前路径上的 fragment（根 Set 的 nested_tree 已含完整嵌套）。
        // 仅当 fragment 没有 modifiers（纯 stub 引用）时，才用该 Set 自己的 nested_tree 展开一次。
        const fragHasMods = Array.isArray(fragmentTree.modifiers) && fragmentTree.modifiers.length > 0;
        const walkTree = fragHasMods
            ? fragmentTree
            : ((msId && full.nested_tree && typeof full.nested_tree === 'object') ? full.nested_tree : fragmentTree);

        const msName = walkTree.display_name || walkTree.set_name || fragmentTree.display_name || fragmentTree.set_name || full.display_name || full.set_name || 'Unknown';
        const msPlatform = String(full.import_type || full.platform || walkTree.platform || '').toUpperCase();
        const msHit = safeCheckMatch(keyword, msName, isRegex, isCaseS) ||
                      safeCheckMatch(keyword, msId, isRegex, isCaseS);
        const keepByAncestor = !!(ancestorHit || msHit);

        const msNode = {
            type: 'Set',
            name: msName,
            id: msId,
            children: [],
            raw: {
                modifier_set_id: msId,
                set_name: walkTree.set_name || full.set_name || '',
                display_name: walkTree.display_name || full.display_name || msName,
                platform: msPlatform,
                import_type: msPlatform || full.import_type || '',
                catalog_type: 'MODIFIER_SET'
            }
        };

        // 用 list.modifiers 补齐无嵌套项；children 只取 walkTree（路径局部），避免子 Set 整图替换
        let completeMods = msId
            ? buildCompleteModEntries(msId, walkTree)
            : (Array.isArray(walkTree.modifiers) ? walkTree.modifiers : []).map(m =>
                typeof m === 'string' ? { name: m, children: [] } : { ...m, children: Array.isArray(m.children) ? m.children : [] }
            );

        completeMods.forEach(mod => {
            const modName = mod.name || 'Unknown';
            const modId = String(mod.modifier_id || '');
            const modHit = safeCheckMatch(keyword, modName, isRegex, isCaseS) ||
                           safeCheckMatch(keyword, modId, isRegex, isCaseS);
            const modNode = {
                type: 'Mod',
                name: modName,
                id: modId,
                children: [],
                raw: {
                    name: modName,
                    modifier_id: modId,
                    price: mod.price,
                    title_l2: mod.title_l2 || '',
                    catalog_type: 'MODIFIER'
                }
            };

            // children 只来自当前 walkTree 路径；缺省时再从 walkTree/full.nested_tree 同层补
            let childSets = (Array.isArray(mod.children) && mod.children.length) ? mod.children.slice() : [];
            if (!childSets.length && walkTree && Array.isArray(walkTree.modifiers)) {
                const hit = walkTree.modifiers.find(m => m && (
                    (modId && String(m.modifier_id || '') === modId) ||
                    (modName && String(m.name || '') === modName)
                ));
                if (hit && Array.isArray(hit.children) && hit.children.length) childSets = hit.children;
            }

            childSets.forEach(childSet => {
                if (!childSet || typeof childSet !== 'object') return;
                const childId = resolveChildModifierSetId(childSet);
                const childKey = childId || ('name:' + String(childSet.display_name || childSet.set_name || '').trim());
                if (childKey && nextSeen.has(childKey)) {
                    if (childId) modNode.raw.cycleToSetId = childId;
                    return;
                }
                if (!childKey || childKey === 'name:') return;

                // stub（无 modifiers）时把该 Set 的 nested_tree 嵌进来再递归，避免只停在第一层
                let nextFragment = childSet;
                const childHasMods = Array.isArray(childSet.modifiers) && childSet.modifiers.length > 0;
                if (!childHasMods && childId) {
                    const childFull = (window.__infiModifierSetsById || {})[childId];
                    if (childFull && childFull.nested_tree && typeof childFull.nested_tree === 'object') {
                        nextFragment = childFull.nested_tree;
                    }
                }

                const childNode = buildNestedModifierSetNode(
                    nextFragment,
                    keyword,
                    keepByAncestor || modHit,
                    nextSeen,
                    depth + 1,
                    isRegex,
                    isCaseS
                );
                if (!childNode) return;
                if (childNode.type === 'SetRef') {
                    modNode.raw.cycleToSetId = childNode.raw && childNode.raw.refSetId
                        ? childNode.raw.refSetId
                        : (childNode.id || childId);
                    return;
                }
                modNode.children.push(childNode);
            });

            if (modNode.children.length === 0) delete modNode.children;
            if (!keyword || modHit || keepByAncestor || (modNode.children && modNode.children.length > 0)) {
                msNode.children.push(modNode);
            }
        });

        if (msNode.children.length === 0) delete msNode.children;
        if (!keyword || keepByAncestor || (msNode.children && msNode.children.length > 0)) return msNode;
        return null;
    }
    function buildFlatModifierSetNode(ms, keyword, ancestorHit, isRegex, isCaseS) {
        if (typeof isRegex !== 'boolean') isRegex = isItemsRegexMode;
        if (typeof isCaseS !== 'boolean') isCaseS = isItemsCaseSensitive;
        const msId = ms.modifier_set_id || '';
        const full = (window.__infiModifierSetsById || {})[msId] || {};
        const msName = ms.display_name || ms.name || full.display_name || full.set_name || 'Unknown';
        const msPlatform = String(window.__infiModifierSetsMap[msId] || full.import_type || full.platform || '').toUpperCase();
        const msHit = safeCheckMatch(keyword, msName, isRegex, isCaseS) ||
                      safeCheckMatch(keyword, msId, isRegex, isCaseS);
        const keepByAncestor = !!(ancestorHit || msHit);
        const msNode = {
            type: 'Set',
            name: msName,
            id: msId,
            children: [],
            raw: { ...full, ...ms, platform: msPlatform, import_type: msPlatform, catalog_type: 'MODIFIER_SET', nested_tree: undefined }
        };
        const mods = Array.isArray(ms.modifiers) ? ms.modifiers : [];
        mods.forEach(mod => {
            const modName = typeof mod === 'string' ? mod : (mod.name || 'Unknown');
            const modId = typeof mod === 'string' ? '' : String(mod.modifier_id || '');
            const modHit = safeCheckMatch(keyword, modName, isRegex, isCaseS) ||
                           safeCheckMatch(keyword, modId, isRegex, isCaseS);
            if (!keyword || modHit || keepByAncestor) {
                msNode.children.push({
                    type: 'Mod',
                    name: modName,
                    id: modId,
                    raw: typeof mod === 'string'
                        ? { name: modName, catalog_type: 'MODIFIER' }
                        : { ...mod, name: modName, modifier_id: modId, catalog_type: 'MODIFIER', children: undefined }
                });
            }
        });
        if (msNode.children.length === 0) delete msNode.children;
        if (!keyword || keepByAncestor || (msNode.children && msNode.children.length > 0)) return msNode;
        return null;
    }
    function itemsNestKey(itemKey, msId, modId, modName) {
        return String(itemKey || '') + '::' + String(msId || '') + '::' + String(modId || modName || '');
    }

    function toggleItemsModNest(nestKey) {
        if (!window.__infiItemsNestExpanded) window.__infiItemsNestExpanded = new Set();
        window.__infiItemsSkipAutoCenter = true;
        const expanding = !window.__infiItemsNestExpanded.has(nestKey);
        if (expanding) window.__infiItemsNestExpanded.add(nestKey);
        else window.__infiItemsNestExpanded.delete(nestKey);

        (async () => {
            // 点嵌套时确保 modifiers-sets（含 nested_tree）已加载
            if (expanding && !window.__infiModifierSetsLoaded) {
                await ensureItemsDetailData(null);
                return; // ensureItemsDetailData 末尾会 redraw
            }
            if (drawItemsTreeRef) drawItemsTreeRef();
        })();
    }

    // 第三页细节：只展第一层 Set→Mod（轻量）；嵌套点按钮后再建完整子树
    function buildItemsModifierSetLazy(ms, keyword, keepFirstLayer, itemKey) {
        const msId = (ms && ms.modifier_set_id) || '';
        const full = msId ? ((window.__infiModifierSetsById || {})[msId] || {}) : {};
        const msName = (ms && (ms.display_name || ms.name)) || full.display_name || full.set_name || 'Unknown';
        const msPlatform = String((window.__infiModifierSetsMap || {})[msId] || full.import_type || full.platform || '').toUpperCase();
        const msHit = safeCheckMatch(keyword, msName, isItemsRegexMode, isItemsCaseSensitive) ||
                      safeCheckMatch(keyword, msId, isItemsRegexMode, isItemsCaseSensitive);
        const keepLayer = !!(keepFirstLayer || msHit);
        const hasKw = hasEffectiveSearchKeyword(keyword);

        const msNode = {
            type: 'Set',
            name: msName,
            id: msId,
            children: [],
            raw: {
                modifier_set_id: msId,
                set_name: full.set_name || (ms && ms.name) || '',
                display_name: msName,
                platform: msPlatform,
                import_type: msPlatform || full.import_type || '',
                catalog_type: 'MODIFIER_SET'
            }
        };

        const mods = listFirstLayerModsForSet(ms, full);

        for (let i = 0; i < mods.length; i++) {
            const mod = mods[i];
            if (!mod) continue;
            const modName = mod.name || 'Unknown';
            const modId = String(mod.modifier_id || '');
            const modHit = hasKw && (
                safeCheckMatch(keyword, modName, isItemsRegexMode, isItemsCaseSensitive) ||
                safeCheckMatch(keyword, modId, isItemsRegexMode, isItemsCaseSensitive)
            );
            // O(1) 索引查嵌套；未展开时不深拷贝 children
            const nestKids = findModNestChildSets(msId, modId, modName);
            const nestKey = itemsNestKey(itemKey, msId, modId, modName);
            let nestHit = false;
            if (hasKw && nestKids) {
                nestHit = nestChildSetsMatchKeyword(nestKids, keyword, isItemsRegexMode, isItemsCaseSensitive, msId);
                if (nestHit) {
                    if (!window.__infiItemsNestExpanded) window.__infiItemsNestExpanded = new Set();
                    window.__infiItemsNestExpanded.add(nestKey);
                }
            }
            const nestExpanded = !!(nestKids && (
                (window.__infiItemsNestExpanded && window.__infiItemsNestExpanded.has(nestKey)) || nestHit
            ));

            if (!hasKw || modHit || nestHit || keepLayer) {
                let price = mod.price;
                if (price == null || price === '') price = lookupModPrice(modId, modName);
                const modNode = {
                    type: 'Mod',
                    name: modName,
                    id: modId,
                    children: [],
                    raw: {
                        name: modName,
                        modifier_id: modId,
                        price,
                        catalog_type: 'MODIFIER',
                        hasNesting: !!nestKids,
                        nestKey,
                        nestExpanded,
                        parentSetId: msId
                    }
                };
                if (nestExpanded && nestKids && nestKids.length) {
                    for (let j = 0; j < nestKids.length; j++) {
                        const cs = nestKids[j];
                        if (!cs || typeof cs !== 'object') continue;
                        const seen = new Set();
                        if (msId) seen.add(String(msId));
                        const child = buildNestedModifierSetNode(
                            cs, '', true,
                            seen, 0, isItemsRegexMode, isItemsCaseSensitive
                        );
                        if (child) modNode.children.push(child);
                    }
                }
                if (modNode.children.length === 0) delete modNode.children;
                msNode.children.push(modNode);
            }
        }

        if (msNode.children.length === 0) delete msNode.children;
        if (!hasKw || keepLayer || (msNode.children && msNode.children.length > 0)) return msNode;
        return null;
    }

    function transformItemsDataForD3(payload, showSub, keyword) {
        const root = { type: 'Library', name: 'categories', id: 'root', children: [] };
        if (!payload || !Array.isArray(payload)) return root;

        const expandSub = !!showSub;
        if (!hasEffectiveSearchKeyword(keyword)) keyword = '';

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

                        const setChildren = [];
                        if (item.modifier_set && Array.isArray(item.modifier_set)) {
                            item.modifier_set.forEach(ms => {
                                const built = buildItemsModifierSetLazy(ms || {}, keyword, !!(itemHit || catHit), itemKey);
                                if (built) setChildren.push(built);
                            });
                        }
                        if (setChildren.length > 0) {
                            itemNode.children.push({ type: 'SetGroup', name: 'Modifier Sets', id: '', children: setChildren, raw: {} });
                        }
                    }

                    if (itemNode.children.length === 0) delete itemNode.children;
                    if (!keyword || itemHit || catHit || (itemNode.children && itemNode.children.length > 0)) {
                        catNode.children.push(itemNode);
                    }
                });
            }

            if (catNode.children.length === 0) delete catNode.children;
            if (!keyword || catHit || (catNode.children && catNode.children.length > 0)) root.children.push(catNode);
        });

        return root;
    }

    function drawItemsTreeD3(payload, validItemKeys) {
        // 批量勾选/重入时合并为一次绘制，避免连环重绘拖死页面
        if (window.__infiItemsDrawing) {
            window.__infiItemsDrawPending = { payload, validItemKeys };
            return;
        }
        window.__infiItemsDrawing = true;
        window.__infiItemsDrawPending = null;
        try {
            drawItemsTreeD3Core(payload, validItemKeys);
        } finally {
            window.__infiItemsDrawing = false;
            const pending = window.__infiItemsDrawPending;
            window.__infiItemsDrawPending = null;
            if (pending) drawItemsTreeD3(pending.payload, pending.validItemKeys);
        }
    }

    function drawItemsTreeD3Core(payload, validItemKeys) {
        const mainGroup = d3.select("#infim-svg-items g");
        mainGroup.selectAll("*").remove();
        window.__infiItemsStickyNode = null;

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
        const allNodes = root.descendants();
        const nodeCount = allNodes.length;
        const heavyTree = nodeCount > 350;
        // 大树略收行距，减少 SVG 高度带来的布局压力
        const dx = heavyTree ? 56 : 100;
        const dy = heavyTree ? 320 : 400;
        const tree = d3.tree().nodeSize([dx, dy]);
        tree(root);

        const matchedNodesSet = new Set();
        const pathLinkNodesSet = new Set();
        if (keyword) {
            allNodes.forEach(d => {
                if (safeCheckMatch(keyword, d.data.name, isItemsRegexMode, isItemsCaseSensitive) ||
                    safeCheckMatch(keyword, d.data.id, isItemsRegexMode, isItemsCaseSensitive)) {
                    matchedNodesSet.add(d);
                    d.ancestors().forEach(anc => pathLinkNodesSet.add(anc));
                }
            });
        }

        function isFirstLayerMod(d) {
            return d && d.data && d.data.type === 'Mod'
                && d.parent && d.parent.data && d.parent.data.type === 'Set'
                && d.parent.parent && d.parent.parent.data && d.parent.parent.data.type === 'SetGroup';
        }
        function baseLinkStroke(d) {
            if (keyword && pathLinkNodesSet.has(d.source) && pathLinkNodesSet.has(d.target)) return ITEMS_LINK_COLOR;
            return '#666666';
        }
        function baseLinkOpacity(d) {
            if (keyword && pathLinkNodesSet.has(d.source) && pathLinkNodesSet.has(d.target)) return 0.95;
            return heavyTree ? 0.35 : 0.55;
        }
        function baseLinkWidth(d) {
            if (keyword && pathLinkNodesSet.has(d.source) && pathLinkNodesSet.has(d.target)) return 4.5;
            return heavyTree ? 1.1 : 1.6;
        }

        const linksData = root.links();
        const linkGen = d3.linkHorizontal().x(d => d.y).y(d => d.x);
        const linkPathSelection = mainGroup.append("g").attr("class", "infim-tree-links").attr("fill", "none")
            .selectAll("path").data(linksData).join("path")
            .attr("d", linkGen)
            .attr("stroke", baseLinkStroke)
            .attr("stroke-opacity", baseLinkOpacity)
            .attr("stroke-width", baseLinkWidth);

        function highlightHoverPath(targetNode) {
            // 大树只高亮祖先链，避免每次 hover 扫 descendants + 全量改 path
            const activeNodes = heavyTree
                ? new Set(targetNode.ancestors())
                : new Set([...targetNode.ancestors(), ...targetNode.descendants()]);
            linkPathSelection
                .attr("stroke", d => (activeNodes.has(d.source) && activeNodes.has(d.target)) ? ITEMS_LINK_COLOR : baseLinkStroke(d))
                .attr("stroke-opacity", d => (activeNodes.has(d.source) && activeNodes.has(d.target)) ? 0.95 : baseLinkOpacity(d))
                .attr("stroke-width", d => (activeNodes.has(d.source) && activeNodes.has(d.target)) ? 4.5 : baseLinkWidth(d));
        }
        function resetHoverHighlight() {
            linkPathSelection
                .attr("stroke", baseLinkStroke)
                .attr("stroke-opacity", baseLinkOpacity)
                .attr("stroke-width", baseLinkWidth);
        }


        // 第一层 Modifier 后方虚线竖线：仅有展开嵌套时才算，避免大树两次全量 filter
        const hasAnyItemsNest = !!(window.__infiItemsNestExpanded && window.__infiItemsNestExpanded.size > 0);
        const firstLayerMods = hasAnyItemsNest ? allNodes.filter(isFirstLayerMod) : [];
        const nestedAfterFirst = hasAnyItemsNest ? allNodes.filter(d =>
            d.parent && isFirstLayerMod(d.parent)
            && (d.data.type === 'Set' || d.data.type === 'SetRef')
        ) : [];
        if (firstLayerMods.length > 0 && nestedAfterFirst.length > 0) {
            const xLine = d3.mean(firstLayerMods, d => d.y) + dy * 0.48;
            const y0 = d3.min(nestedAfterFirst.concat(firstLayerMods), d => d.x) - 28;
            const y1 = d3.max(nestedAfterFirst.concat(firstLayerMods), d => d.x) + 28;
            mainGroup.append('line')
                .attr('class', 'infim-nest-sep')
                .attr('x1', xLine).attr('x2', xLine)
                .attr('y1', y0).attr('y2', y1)
                .attr('stroke', '#d946ef')
                .attr('stroke-dasharray', '7,5')
                .attr('stroke-width', 3.2)
                .attr('stroke-opacity', 0.95);
        }

        // 环回：SetRef -> 已出现的同 id Set
        try {
            const svgRoot = d3.select('#infim-svg-items');
            if (svgRoot.select('defs').empty()) svgRoot.insert('defs', ':first-child');
            if (svgRoot.select('#infim-cycle-arrow').empty()) {
                svgRoot.select('defs').append('marker')
                    .attr('id', 'infim-cycle-arrow')
                    .attr('viewBox', '0 0 10 10')
                    .attr('refX', 9).attr('refY', 5)
                    .attr('markerWidth', 7).attr('markerHeight', 7)
                    .attr('orient', 'auto-start-reverse')
                    .append('path').attr('d', 'M 0 0 L 10 5 L 0 10 z').attr('fill', '#d946ef');
            }
        } catch (_) {}
        function findAncestorSetById(node, setId) {
            const want = String(setId || '');
            if (!want || !node) return null;
            let p = node.parent;
            while (p) {
                if (p.data && p.data.type === 'Set' && String(p.data.id || '') === want) return p;
                p = p.parent;
            }
            return null;
        }
        // 无展开嵌套时几乎没有环边，跳过全量扫描
        const cycleLinks = [];
        if (hasAnyItemsNest) {
            allNodes.forEach(d => {
                if (d.data.type === 'Mod' && d.data.raw && d.data.raw.cycleToSetId) {
                    const target = findAncestorSetById(d, d.data.raw.cycleToSetId);
                    if (target) cycleLinks.push({ source: d, target });
                    else delete d.data.raw.cycleToSetId;
                    return;
                }
                if (d.data.type === 'SetRef') {
                    const refId = (d.data.raw && d.data.raw.refSetId) || d.data.id;
                    const target = findAncestorSetById(d, refId);
                    if (target) cycleLinks.push({ source: d, target });
                }
            });
        }
        mainGroup.append('g').attr('class', 'infim-cycle-links').attr('fill', 'none')
            .selectAll('path').data(cycleLinks).join('path')
            .attr('d', d => {
                const x1 = d.source.y, y1 = d.source.x, x2 = d.target.y, y2 = d.target.x;
                const sweep = (y1 < y2 ? -1 : 1) * (36 + Math.abs(y1 - y2) * 0.15);
                const mx = (x1 + x2) / 2;
                const my = (y1 + y2) / 2 + sweep;
                return 'M' + x1 + ',' + y1 + ' Q' + mx + ',' + my + ' ' + x2 + ',' + y2;
            })
            .attr('stroke', '#d946ef')
            .attr('stroke-dasharray', '6,4')
            .attr('stroke-width', 2)
            .attr('stroke-opacity', 0.9)
            .attr('marker-end', 'url(#infim-cycle-arrow)');

        function isItemsTextOnRight(d) { return !d.children || d.children.length === 0; }

        const node = mainGroup.append("g").attr("stroke-linejoin", "round").attr("stroke-width", 3)
            .selectAll("g").data(root.descendants()).join("g")
            .attr("transform", d => `translate(${d.y},${d.x})`);

        node.append("circle")
            .attr("fill", d => d.data.type === 'SetRef' ? '#fdf4ff' : (d.children ? "#555" : "#999"))
            .attr("stroke", d => d.data.type === 'SetRef' ? '#d946ef' : 'none')
            .attr("stroke-width", d => d.data.type === 'SetRef' ? 1.6 : 1)
            .attr("stroke-dasharray", d => d.data.type === 'SetRef' ? '3,2' : null)
            .attr("r", 5)
            .on("mouseover", (event, d) => { currentHoveredData = d; highlightHoverPath(d); if (!isPanelLocked) showNodeAttributesInPanel(d); })
            .on("mouseout", () => {
                // 离开节点：只保留搜索命中链路，细节 hover 高亮必须清掉（不再 sticky）
                currentHoveredData = null;
                window.__infiItemsStickyNode = null;
                resetHoverHighlight();
                if (!isPanelLocked) document.getElementById("infim-tooltip-panel").style.display = 'none';
            })
            .on("click", (event, d) => {
                event.stopPropagation();
                highlightHoverPath(d);
                if (!isPanelLocked) showNodeAttributesInPanel(d);
            });

        const nameText = node.append("text")
            .attr("class", "infim-tree-name-text infim-tree-name-clickable")
            .attr("dy", "-0.3em")
            .attr("text-anchor", d => isItemsTextOnRight(d) ? "start" : "end").attr("font-weight", "bold")
            .on("mouseover", (event, d) => { currentHoveredData = d; highlightHoverPath(d); if (!isPanelLocked) showNodeAttributesInPanel(d); })
            .on("mouseout", () => {
                currentHoveredData = null;
                window.__infiItemsStickyNode = null;
                resetHoverHighlight();
                if (!isPanelLocked) document.getElementById("infim-tooltip-panel").style.display = 'none';
            })
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

            // 根节点与面板1 Merchant / 面板2 Menu 同级：30px + 900 字重
            if (typeUpper === 'LIBRARY') selection.attr("font-size", "30px").attr("font-weight", "900");
            else if (typeUpper === 'CATEGORY') selection.attr("font-size", "23px").attr("font-weight", "bold");
            else if (typeUpper === 'ITEM') selection.attr("font-size", "20px").attr("font-weight", "bold");
            else if (['VARGROUP', 'SETGROUP'].includes(typeUpper)) selection.attr("font-size", "17px").attr("font-weight", "bold");
            else selection.attr("font-size", "16px").attr("font-weight", "bold");

            // type prefix — skip only for Variations / Modifier Sets 分组节点
            const skipTypePrefix = typeUpper === 'VARGROUP' || typeUpper === 'SETGROUP';
            if (d.data.type && !skipTypePrefix) {
                const typeLabel = typeUpper === 'VAR' ? 'Var' : (typeUpper === 'SETREF' ? 'Set↻' : d.data.type);
                selection.append("tspan").text(`${typeLabel}: `).attr("fill", "#d946ef").attr("font-weight", "900");
            }

            const nameColor = safeCheckMatch(itemsSearchKeyword, d.data.name, isItemsRegexMode, isItemsCaseSensitive) ? "red" : "#111111";
            // group nodes rendered in muted color
            const finalColor = ['VARGROUP', 'SETGROUP'].includes(typeUpper) ? "#888" : nameColor;
            selection.append("tspan").attr("class", "infim-tspan-name").text(d.data.name).attr("fill", finalColor)
                .attr("font-weight", typeUpper === 'LIBRARY' ? "900" : null);

            // price for ITEM / VAR / MOD（嵌套 Set 不标价，避免节点膨胀）
            if (['ITEM', 'VAR', 'VARIATION', 'MOD'].includes(typeUpper)) {
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

            if (typeUpper === 'SETREF' || (typeUpper === 'MOD' && d.data.raw && d.data.raw.cycleToSetId)) {
                selection.append("tspan").text(" ↻环回").attr("fill", "#d946ef").attr("font-weight", "700");
            }
            if (typeUpper !== 'SETREF') {
                const childCount = d.children ? d.children.length : 0;
                if (childCount > 0) selection.append("tspan").text(` [${childCount}]`).attr("fill", COUNT_COLOR).attr("font-weight", "bold");
            }
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

            // 有嵌套的 Mod：点按钮再加载深层（细节默认不加载嵌套）
            if (typeUpper === 'MOD' && d.data.raw && d.data.raw.hasNesting && d.data.raw.nestKey) {
                const nestKey = d.data.raw.nestKey;
                const nestOn = !!(window.__infiItemsNestExpanded && window.__infiItemsNestExpanded.has(nestKey));
                const label = nestOn ? '收起嵌套' : '嵌套 ▸';
                const nameLen = this.getComputedTextLength() || 50;
                const btnG = d3.select(this.parentNode).append('g')
                    .attr('class', 'infim-items-nest-btn')
                    .style('cursor', 'pointer')
                    .on('mouseover', e => { e.stopPropagation(); if (!isPanelLocked) document.getElementById('infim-tooltip-panel').style.display = 'none'; })
                    .on('click', function(evt) {
                        evt.stopPropagation();
                        evt.preventDefault();
                        toggleItemsModNest(nestKey);
                    });
                const probe = btnG.append('text').attr('x', 0).attr('y', 0)
                    .style('font-size', '13px').style('font-weight', '700')
                    .style('pointer-events', 'none').attr('opacity', 0).text(label);
                const tw = (probe.node().getComputedTextLength() || 48) + 12;
                probe.remove();
                const bh = 16;
                const textCenterY = -7;
                const bx = nestOn ? 14 : (isRight ? (currentX + nameLen + 8) : 14);
                const by = textCenterY - bh / 2;
                btnG.append('rect')
                    .attr('x', bx).attr('y', by).attr('width', tw).attr('height', bh)
                    .attr('rx', 3).attr('ry', 3)
                    .attr('fill', nestOn ? '#8b5cf6' : '#ff0055')
                    .attr('stroke', nestOn ? '#5b21b6' : '#be123c')
                    .attr('stroke-width', 1.25);
                btnG.append('text')
                    .attr('x', bx + tw / 2).attr('y', textCenterY)
                    .attr('dominant-baseline', 'central').attr('text-anchor', 'middle')
                    .style('font-size', '13px').style('font-weight', '700')
                    .style('pointer-events', 'none').attr('fill', '#fff').text(label);
            }
        });

        // 大树跳过白色描边克隆（节点数翻倍是卡顿主因之一），功能不变
        if (!heavyTree) {
            nameText.clone(true).lower().attr("class", "").attr("stroke", "rgba(255,255,255,0.85)").attr("stroke-width", 3)
                .on("click", null).on("mouseover", null).on("mouseout", null)
                .selectAll("tspan").attr("fill", null).attr("stroke", "rgba(255,255,255,0.85)");
        }

        const idGroup = node.append("g").attr("class", "infim-id-hotspot-g")
            .on("mouseover", e => { e.stopPropagation(); if (!isPanelLocked) document.getElementById("infim-tooltip-panel").style.display = 'none'; });

        const idText = idGroup.append("text").attr("class", "infim-tree-id-text").attr("y", d => (d.data.type === 'Set' || d.data.type === 'Mod' || d.data.type === 'SetRef') ? 26 : 16)
            .style("pointer-events", "none")
            .attr("x", d => isItemsTextOnRight(d) ? 8 : -8)
            .attr("text-anchor", d => isItemsTextOnRight(d) ? "start" : "end")
            .text(d => d.data.id && d.data.id !== "N/A" && d.data.id !== 'root' && d.data.id !== 'default' ? `ID: ${d.data.id}` : "")
            .attr("font-size", "15px")
            .attr("fill", d => safeCheckMatch(itemsSearchKeyword, d.data.id, isItemsRegexMode, isItemsCaseSensitive) ? "red" : "#666")
            .attr("font-weight", "500");

        idText.each(function(d) {
            if (!d.data.id || d.data.id === 'root' || d.data.id === 'default') return;
            const isRight = isItemsTextOnRight(d);
            const startX = isRight ? 8 : -8;
            const idY = (d.data.type === 'Set' || d.data.type === 'Mod' || d.data.type === 'SetRef') ? 26 : 16;
            // Item 旁有 [显示Menu]：必须实测宽度，估算偏短会叠住 ID
            const needExactIdWidth = d.data.type === 'Item' || !heavyTree;
            const textLen = needExactIdWidth
                ? (this.getComputedTextLength() || (d.data.id.length * 8))
                : Math.max(40, (`ID: ${d.data.id}`).length * 8.2);
            const rectX = isRight ? startX - 4 : startX - textLen - 4;
            d3.select(this.parentNode).insert("rect", "text")
                .attr("class", "id-hotspot-catcher").attr("y", idY - 14).attr("x", rectX)
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

            // [显示Menu]：跟在 ID 后方，加大间距避免压住 ID
            if (d.data.type === 'Item' && d.data.id !== 'N/A') {
                const gap = 28;
                const currentOffset = isRight ? (startX + textLen + gap) : (startX - textLen - gap);
                const capturedD = d;
                const btnG = d3.select(this.parentNode.parentNode).append("g")
                    .attr("class", "infim-show-menu-btn")
                    .style("cursor", "pointer")
                    .on("mouseover", e => { e.stopPropagation(); if (!isPanelLocked) document.getElementById("infim-tooltip-panel").style.display = 'none'; })
                    .on("click", function(evt) {
                        evt.stopPropagation(); evt.preventDefault();
                        fetchAndShowItemMenuNames(capturedD.data.id, capturedD, d3.select(this).select(".infim-btn-action").node());
                    });
                const btnTxt = btnG.append("text").attr("class", "infim-btn-action").attr("y", idY)
                    .style("pointer-events", "none")
                    .attr("x", currentOffset).attr("text-anchor", isRight ? "start" : "end")
                    .text("[显示Menu]").style("fill", "#f59e0b").style("font-size", "15px").style("font-weight", "900");
                const btnLen = btnTxt.node().getComputedTextLength() || 72;
                const btnRectX = isRight ? currentOffset - 4 : currentOffset - btnLen - 4;
                btnG.insert("rect", "text").attr("y", idY - 14).attr("x", btnRectX).attr("width", btnLen + 8).attr("height", 18).attr("fill", "transparent").style("pointer-events", "all");
            }
        });

        // 连线抬到遮罩之上，文字/圆点仍压在最上层
        try {
            mainGroup.select('g.infim-tree-links').raise();
            mainGroup.select('g.infim-cycle-links').raise();
            mainGroup.selectAll('g.infim-id-hotspot-g').raise();
            mainGroup.selectAll('g.infim-show-menu-btn').raise();
            mainGroup.selectAll('g.infim-items-nest-btn').raise();
            mainGroup.selectAll('text.infim-tree-name-text').raise();
            mainGroup.selectAll('circle').raise();
        } catch (_) {}
        const svg = d3.select("#infim-svg-items");
        const zoom = d3.zoom().scaleExtent([0.05, 4]).on("zoom", (event) => mainGroup.attr("transform", event.transform));

        if (window.__infiItemsSkipAutoCenter) {
            window.__infiItemsSkipAutoCenter = false;
        } else if (window.__infiItemsForceAutoCenter) {
            autoCenterTree(svg, zoom, root.descendants(), 500, 0.65);
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

    // 当前 Menu 对应门店：优先 __infiCurrentLocationId，其次 menu→location 索引
    function resolveLocationLabelForMenu(menuId) {
        const locId = window.__infiCurrentLocationId
            || (menuId && (window.__infiMenuToLocationMap || {})[menuId])
            || '';
        if (!locId) return null;
        const locs = (window.__infiMerchantPayload && window.__infiMerchantPayload.locations) || [];
        let locName = '';
        for (let i = 0; i < locs.length; i++) {
            const loc = locs[i];
            if (!loc) continue;
            if (String(loc.location_id || loc.id || '') === String(locId)) {
                locName = loc.name || loc.title || '';
                break;
            }
        }
        if (!locName) locName = String(locId);
        return { locId: String(locId), locName: String(locName) };
    }

    function getLocationNameById(locId) {
        if (!locId) return '';
        const locs = (window.__infiMerchantPayload && window.__infiMerchantPayload.locations) || [];
        for (let i = 0; i < locs.length; i++) {
            const loc = locs[i];
            if (!loc) continue;
            if (String(loc.location_id || loc.id || '') === String(locId)) {
                return loc.name || loc.title || String(locId);
            }
        }
        return String(locId);
    }

    // 同名 Menu 可能在多个 location：返回全部命中
    function lookupAllMenusByName(menuName) {
        if (!menuName) return [];
        const hits = [];
        const seen = new Set();
        const pushHit = (menuId, locationId) => {
            if (!menuId) return;
            const locId = locationId || (window.__infiMenuToLocationMap || {})[menuId] || '';
            const key = String(menuId) + '@' + String(locId);
            if (seen.has(key)) return;
            seen.add(key);
            hits.push({
                menuId: String(menuId),
                locationId: locId ? String(locId) : null,
                menuName,
                locName: locId ? getLocationNameById(locId) : ''
            });
        };

        const locs = (window.__infiMerchantPayload && window.__infiMerchantPayload.locations) || [];
        locs.forEach(loc => {
            if (!loc) return;
            const locId = loc.location_id || loc.id || '';
            const menus = loc._loadedMenus || [];
            menus.forEach(m => {
                if (!m) return;
                if ((m.menu_name || m.name) === menuName && m.menu_id) pushHit(m.menu_id, locId);
            });
        });

        const mapped = (window.__infiMenuNameToIdMap || {})[menuName];
        if (Array.isArray(mapped)) {
            mapped.forEach(x => {
                if (!x) return;
                if (typeof x === 'string') pushHit(x, null);
                else pushHit(x.menuId, x.locationId);
            });
        } else if (mapped) {
            pushHit(mapped, null);
        }
        return hits;
    }

    function lookupMenuByName(menuName) {
        const all = lookupAllMenusByName(menuName);
        return all.length ? all[0] : null;
    }

    async function ensureAllLocationMenusLoaded() {
        const mId = localStorage.getItem('__infi_last_detected_merchant_id');
        const locs = (window.__infiMerchantPayload && window.__infiMerchantPayload.locations) || [];
        if (!mId || !locs.length) return;
        const host = window.location.origin;
        const finalHeaders = buildAuthHeaders();
        const needFetch = locs.filter(loc => !loc._hasLoadedMenus && !loc._loadedMenus);
        await Promise.all(needFetch.map(async loc => {
            const locId = loc.location_id || loc.id;
            if (!locId) return;
            try {
                const res = await originalFetch(
                    `${host}/merchant-portal-api/v1/merchants/${mId}/location/${locId}/menu`,
                    { method: 'GET', headers: finalHeaders }
                );
                const data = await res.json();
                if (data && data.code === "SUCCESS") injectLocationMenus(locId, data.payload, false);
            } catch (e) { /* skip */ }
        }));
    }

    async function resolveAllMenusByName(menuName) {
        let hits = lookupAllMenusByName(menuName);
        if (hits.length) return hits;
        await ensureAllLocationMenusLoaded();
        return lookupAllMenusByName(menuName);
    }

    async function resolveMenuRefByName(menuName) {
        const all = await resolveAllMenusByName(menuName);
        return all.length ? all[0] : null;
    }

    function applyMenuSearchAndSlide(itemId) {
        const kw = String(itemId || '').trim();
        rightSearchKeyword = kw;
        // 用精确匹配搜 item id，避免正则误伤
        isRightRegexMode = false;
        const rSearchInput = document.querySelector('#infim-right-search-control input');
        if (rSearchInput) rSearchInput.value = kw;
        const rRegexBtn = document.querySelector('#infim-right-search-control .infim-search-toggle-btn');
        // 第一个 .* 按钮：关掉模糊
        const regexBtns = document.querySelectorAll('#infim-right-search-control .infim-search-toggle-btn');
        if (regexBtns && regexBtns[0]) {
            regexBtns[0].classList.toggle('active', isRightRegexMode);
            regexBtns[0].title = isRightRegexMode
                ? "模糊搜索(含子串/正则) — 点击切换精确匹配"
                : "精确匹配 — 点击切换模糊搜索";
        }
        window.__infiForceMenuAutoCenter = true;
        window.__infiShowSubItems = true;
        const detailBtn = document.querySelector('#infim-right-search-control .infim-detail-toggle-btn');
        if (detailBtn) detailBtn.classList.add('active');
        slideView('right');
        if (drawMenuTreeRef) drawMenuTreeRef();
    }

    async function openMenuAndSearchItem(menuId, itemId, locationId, btnEl) {
        if (!menuId) return showToast("未找到对应 Menu ID ok");
        const mId = localStorage.getItem('__infi_last_detected_merchant_id');
        if (!mId) return showToast("暂未捕获到商户ID ok");

        // 已是同一份 menu：直接搜
        if (window.__infiMenuPayload && window.__infiMenuPayload.menu_id === menuId) {
            if (btnEl) btnEl.textContent = "✓";
            applyMenuSearchAndSlide(itemId);
            return;
        }

        if (btnEl) {
            btnEl.textContent = "加载中";
            btnEl.style.opacity = "0.7";
        }

        const host = window.location.origin;
        const finalHeaders = buildAuthHeaders();
        const locId = locationId || (window.__infiMenuToLocationMap || {})[menuId] || window.__infiCurrentLocationId || null;
        try {
            const tasks = [
                originalFetch(`${host}/merchant-portal-api/v1/merchants/${mId}/menu/${menuId}`, { method: 'GET', headers: finalHeaders }),
                originalFetch(`${host}/merchant-portal-api/v1/merchants/${mId}/modifiers-sets`, { method: 'GET', headers: finalHeaders }),
            ];
            if (locId) {
                tasks.push(originalFetch(
                    `${host}/merchant-portal-api/v1/merchants/${mId}/get-products/${locId}`,
                    { method: 'GET', headers: finalHeaders }
                ));
            }
            const responses = await Promise.all(tasks);
            const datas = await Promise.all(responses.map(r => r.json()));
            const data = datas[0];
            const modSetsData = datas[1];
            const varPlatformData = datas[2];
            if (modSetsData && modSetsData.code === "SUCCESS") handleModifierSetsIntercept(modSetsData.payload);
            if (varPlatformData && varPlatformData.code === "SUCCESS") handleVariationPlatformIntercept(varPlatformData.payload);
            if (data && data.code === "SUCCESS" && data.payload) {
                window.__infiMenuPayload = data.payload;
                persistMenuPayloadMeta(data.payload);
                harvestModPricesFromMenuPayload(data.payload);
                if (locId) window.__infiCurrentLocationId = locId;
                const rightDropdown = document.getElementById("infim-menu-dropdown");
                if (rightDropdown) rightDropdown.innerHTML = '';
                if (btnEl) {
                    btnEl.textContent = "✓打开";
                    btnEl.style.opacity = "";
                    btnEl.style.color = "#52c41a";
                    btnEl.style.borderColor = "#52c41a";
                }
                applyMenuSearchAndSlide(itemId);
            } else {
                if (btnEl) { btnEl.textContent = "在menu中展示"; btnEl.style.opacity = ""; }
                showToast(formatApiError(data, finalHeaders));
            }
        } catch (e) {
            if (btnEl) { btnEl.textContent = "在menu中展示"; btnEl.style.opacity = ""; }
            showToast(`Network Error: ${e.message}`);
        }
    }

    function normalizeMenuListEntries(payload) {
        const out = [];
        const seen = new Set();
        const push = (name, id) => {
            const n = (name || '').trim();
            if (!n && !id) return;
            const key = (id || '') + '|' + n;
            if (seen.has(key)) return;
            seen.add(key);
            out.push({ name: n || id, menuId: id || '' });
        };
        const names = payload && payload.menu_names;
        if (Array.isArray(names)) {
            names.forEach(x => {
                if (typeof x === 'string') push(x, '');
                else if (x && typeof x === 'object') push(x.menu_name || x.name || '', x.menu_id || x.id || '');
            });
        }
        const menus = (payload && (payload.menus || payload.menu_list)) || [];
        if (Array.isArray(menus)) {
            menus.forEach(m => {
                if (!m) return;
                if (typeof m === 'string') push(m, '');
                else push(m.menu_name || m.name || '', m.menu_id || m.id || '');
            });
        }
        return out;
    }

    // 同名 Menu 按已加载的 location 拆成多行；未知 location 的先保留原名，点开时再解析
    function expandMenuEntriesByLocation(entries) {
        const out = [];
        const seen = new Set();
        (Array.isArray(entries) ? entries : []).forEach(entry => {
            const name = typeof entry === 'string' ? entry : (entry.name || '');
            const knownId = typeof entry === 'object' ? (entry.menuId || '') : '';
            if (knownId) {
                const locId = (window.__infiMenuToLocationMap || {})[knownId] || (entry.locationId || '');
                const key = knownId + '@' + (locId || '');
                if (seen.has(key)) return;
                seen.add(key);
                out.push({
                    name,
                    menuId: knownId,
                    locationId: locId || null,
                    locName: locId ? getLocationNameById(locId) : ''
                });
                return;
            }
            const hits = lookupAllMenusByName(name);
            if (hits.length > 0) {
                hits.forEach(h => {
                    const key = h.menuId + '@' + (h.locationId || '');
                    if (seen.has(key)) return;
                    seen.add(key);
                    out.push({
                        name,
                        menuId: h.menuId,
                        locationId: h.locationId,
                        locName: h.locName || (h.locationId ? getLocationNameById(h.locationId) : '')
                    });
                });
            } else {
                const key = '|' + name;
                if (seen.has(key)) return;
                seen.add(key);
                out.push({ name, menuId: '', locationId: null, locName: '' });
            }
        });
        return out;
    }

    function appendMenuNamesToPanel(menuEntries, itemId) {
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

        const list = expandMenuEntriesByLocation(menuEntries);
        if (list.length === 0) {
            const empty = document.createElement('div');
            empty.style.cssText = "font-size:11px; color:#aaa; font-style:italic;";
            empty.textContent = "(无所属菜单)";
            section.appendChild(empty);
        } else {
            list.forEach(entry => {
                const name = entry.name || '';
                const knownId = entry.menuId || '';
                const knownLocId = entry.locationId || '';
                const knownLocName = entry.locName || (knownLocId ? getLocationNameById(knownLocId) : '');

                const row = document.createElement('div');
                row.style.cssText = "display:flex; align-items:flex-start; justify-content:space-between; padding:5px 0; border-bottom:1px solid rgba(0,0,0,0.05); gap:6px;";

                const leftCol = document.createElement('div');
                leftCol.style.cssText = "flex:1; min-width:0; display:flex; flex-direction:column; gap:2px;";

                const nameSpan = document.createElement('span');
                nameSpan.style.cssText = "font-size:11px; color:#111; font-weight:600; word-break:break-all; cursor:pointer;";
                nameSpan.title = "点击复制菜单名";
                nameSpan.textContent = name;
                nameSpan.onclick = (e) => {
                    e.stopPropagation();
                    const prev = nameSpan.textContent;
                    navigator.clipboard.writeText(name).then(() => {
                        nameSpan.textContent = "✓ 已复制";
                        nameSpan.style.color = "#52c41a";
                        setTimeout(() => {
                            nameSpan.textContent = prev;
                            nameSpan.style.color = "#111";
                        }, 900);
                    });
                };
                leftCol.appendChild(nameSpan);

                const locSpan = document.createElement('span');
                locSpan.style.cssText = "font-size:10px; color:#9ca3af; word-break:break-all;";
                if (knownLocName || knownLocId) {
                    locSpan.textContent = `${knownLocName || knownLocId} : ${knownLocId || ''}`;
                } else {
                    locSpan.textContent = "未匹配到门店（将在点击时解析）";
                    locSpan.style.color = "#ccc";
                    locSpan.style.fontStyle = "italic";
                }
                leftCol.appendChild(locSpan);

                const openBtn = document.createElement('span');
                openBtn.style.cssText = "font-size:10px; color:#fff; background:#52c41a; font-weight:800; cursor:pointer; white-space:nowrap; padding:2px 6px; border-radius:3px; border:1px solid #389e0d; text-align:center; flex-shrink:0; align-self:flex-start;";
                openBtn.textContent = "在menu中展示";
                openBtn.title = "加载该 Menu，并搜索高亮当前 Item ID";

                openBtn.onclick = async (e) => {
                    e.stopPropagation();
                    // 清掉本区块其它 location 选择器
                    section.querySelectorAll('.infim-menu-loc-picker').forEach(el => el.remove());

                    openBtn.textContent = "解析中";
                    let menuId = knownId;
                    let locationId = knownLocId || (menuId ? ((window.__infiMenuToLocationMap || {})[menuId] || null) : null);

                    if (!menuId) {
                        const refs = await resolveAllMenusByName(name);
                        if (!refs.length) {
                            openBtn.textContent = "在menu中展示";
                            return showToast("未在门店菜单列表中找到该 Menu，请先在面板1加载门店菜单 ok");
                        }
                        if (refs.length === 1) {
                            menuId = refs[0].menuId;
                            locationId = refs[0].locationId;
                        } else {
                            // 同名多店：展开选择
                            openBtn.textContent = "选门店";
                            const picker = document.createElement('div');
                            picker.className = 'infim-menu-loc-picker';
                            picker.style.cssText = "width:100%; margin:4px 0 8px 0; padding:6px 8px; background:rgba(0,0,0,0.03); border-radius:4px; border:1px solid rgba(0,0,0,0.06);";
                            const tip = document.createElement('div');
                            tip.style.cssText = "font-size:10px; color:#f59e0b; font-weight:800; margin-bottom:4px;";
                            tip.textContent = `同名 Menu 出现在 ${refs.length} 个门店，请选择：`;
                            picker.appendChild(tip);
                            refs.forEach(ref => {
                                const opt = document.createElement('div');
                                opt.style.cssText = "font-size:11px; color:#555; padding:4px 0; cursor:pointer; border-bottom:1px solid rgba(0,0,0,0.04);";
                                opt.textContent = `${ref.locName || ref.locationId || '未知门店'} : ${ref.locationId || ''}`;
                                opt.title = `Menu ID: ${ref.menuId}`;
                                opt.onmouseenter = () => { opt.style.color = "#52c41a"; };
                                opt.onmouseleave = () => { opt.style.color = "#555"; };
                                opt.onclick = async (ev) => {
                                    ev.stopPropagation();
                                    picker.remove();
                                    await openMenuAndSearchItem(ref.menuId, itemId, ref.locationId, openBtn);
                                };
                                picker.appendChild(opt);
                            });
                            row.insertAdjacentElement('afterend', picker);
                            return;
                        }
                    }
                    await openMenuAndSearchItem(menuId, itemId, locationId, openBtn);
                };

                row.appendChild(leftCol);
                row.appendChild(openBtn);
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
                const entries = normalizeMenuListEntries(data.payload);
                // 先展示一层（可能尚无 loc）；再拉齐各店菜单后按同名拆出行并补 location
                appendMenuNamesToPanel(entries, itemId);
                el.text("[解析门店...]");
                try {
                    await ensureAllLocationMenusLoaded();
                } catch (_) { /* ignore */ }
                appendMenuNamesToPanel(entries, itemId);
                el.text("[显示Menu]");
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
        // 异常中断后绘制锁可能残留，这里清掉以免下拉有了但树永远不刷新
        window.__infiItemsDrawing = false;
        window.__infiItemsDrawPending = null;

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
            // 清搜索后若仍开细节，会展开全部 Item 嵌套 → 极易 OOM，自动关闭
            if (window.__infiShowItemsSubItems) {
                window.__infiShowItemsSubItems = false;
                const detailBtn = document.querySelector('#infim-items-search-control .infim-detail-toggle-btn');
                if (detailBtn) detailBtn.classList.remove('active');
            }
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

                    const ref = { catKey, catName, itemKey, itemName, compositeKey, itemCb, labelSpan, row: itemRow, rawItem: item };
                    catItemRefs.push(ref);
                    allItemRefs.push(ref);

                    itemCb.onchange = () => {
                        if (window.__infiItemsBulkToggle) return;
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

                // Category checkbox: bulk toggle all its items（只改状态，不触发 item change）
                catCb.onchange = () => {
                    if (window.__infiItemsBulkToggle) return;
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
                    const nestHit = !!(r.rawItem && Array.isArray(r.rawItem.modifier_set)
                        && modifierSetsHaveNestedKeywordMatch(r.rawItem.modifier_set, keyword, isItemsRegexMode, isItemsCaseSensitive));
                    if (catHit || itemHit || nestHit) {
                        r.row.style.display = '';
                        r.labelSpan.innerHTML = `<span style="color:red;font-weight:bold;">${r.itemName}</span>`;
                        r.itemCb.checked = true; validItemKeys.add(r.compositeKey);
                        if (itemHit || nestHit) { catHasItemHit = true; matchCount++; }
                    } else {
                        // 下拉隐藏的同时从树过滤集移除，否则同 category 已勾选项仍会画出来
                        r.row.style.display = 'none';
                        validItemKeys.delete(r.compositeKey);
                    }
                });

                if (catHit || catHasItemHit) {
                    catHeader.catBlock.style.display = '';
                    catHeader.itemsContainer.style.display = '';
                    catHeader.arrow.textContent = '▼';
                    if (catHit) {
                        catHeader.nameSpan.innerHTML = `<span style="color:#d946ef;font-size:11px;margin-right:3px;">[Cat]</span><span style="color:red;font-weight:bold;">${catHeader.catName}</span>`;
                        matchCount++;
                        // category 名命中：展示该 cat 下全部 item，并恢复进过滤集
                        catHeader.itemRefs.forEach(r => {
                            r.row.style.display = '';
                            r.labelSpan.innerHTML = `<span>${r.itemName}</span>`;
                            if (r.itemCb.checked) validItemKeys.add(r.compositeKey);
                        });
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
                catHeader.itemRefs.forEach(r => {
                    r.row.style.display = '';
                    r.labelSpan.innerHTML = `<span>${r.itemName}</span>`;
                    // 清空搜索后按勾选状态恢复树过滤集
                    if (r.itemCb.checked) validItemKeys.add(r.compositeKey);
                    else validItemKeys.delete(r.compositeKey);
                });
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
    // 开「细节」：必须有 modifiers-sets（含 nested_tree），否则只能画出第一层 flat Set→Mod
    async function ensureItemsDetailData(btnElement) {
        const mId = localStorage.getItem('__infi_last_detected_merchant_id');
        const host = window.location.origin;
        if (!mId) {
            showToast("暂未捕获到商户ID，请先打开商户页面 ok");
            if (drawItemsTreeRef) drawItemsTreeRef();
            return;
        }
        const finalHeaders = buildAuthHeaders();
        if (btnElement) {
            btnElement.classList.add('infim-refresh-loading-active');
            btnElement.style.opacity = '0.7';
        }
        try {
            const tasks = [
                originalFetch(`${host}/merchant-portal-api/v1/merchants/${mId}/modifiers-sets`, { method: 'GET', headers: finalHeaders })
            ];
            if (!window.__infiItemsLoaded) {
                tasks.push(originalFetch(`${host}/merchant-portal-api/v1/merchants/${mId}/get-products`, { method: 'GET', headers: finalHeaders }));
            }
            const responses = await Promise.all(tasks);
            const datas = await Promise.all(responses.map(r => r.json()));
            const modSetsData = datas[0];
            if (modSetsData && modSetsData.code === "SUCCESS") {
                handleModifierSetsIntercept(modSetsData.payload);
            } else if (modSetsData) {
                showToast(formatApiError(modSetsData, finalHeaders));
            }
            if (datas[1] && datas[1].code === "SUCCESS") {
                window.__infiItemsPayload = datas[1].payload;
                window.__infiItemsLoaded = true;
                const dropdown = document.getElementById("infim-items-dropdown");
                if (dropdown) dropdown.innerHTML = '';
                window.__infiItemsCatRefs = null;
                window.__infiItemsValidKeys = null;
                window.__infiItemsExpandedCats = null;
            }
            if (drawItemsTreeRef) drawItemsTreeRef();
        } catch (e) {
            showToast(`Network Error: ${e.message}`);
            if (drawItemsTreeRef) drawItemsTreeRef();
        } finally {
            if (btnElement) {
                btnElement.classList.remove('infim-refresh-loading-active');
                btnElement.style.opacity = '';
            }
        }
    }

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