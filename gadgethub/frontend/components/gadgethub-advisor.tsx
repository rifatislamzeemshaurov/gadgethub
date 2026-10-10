'use client';

import { useRef, useState, useEffect } from 'react';
import { Send, Sparkles, User, Info, Paperclip, PlusCircle } from 'lucide-react';

interface Product {
    category: string | null;
    brand_or_make: string | null;
    product_name: string | null;
    price: string | null;
    specs: Record<string, string>;
}

interface Message {
    id: string;
    role: 'user' | 'assistant';
    content: string;
    products?: Product[];
    timestamp: Date;
}

const API_URL = process.env.NEXT_PUBLIC_API_URL || 'http://localhost:8000';
const API_KEY = process.env.NEXT_PUBLIC_API_KEY || '';

const SUGGESTIONS = [
    'I need a laptop that can handle 4K video editing',
    'Recommend a smartwatch for tracking runs',
    "What's a good TV for a bright living room?",
    'Upload a product spec sheet for alternatives',
];

const CATEGORY_META: Record<string, { label: string; classes: string }> = {
    camera: { label: 'Camera', classes: 'bg-fuchsia-500/10 text-fuchsia-300 ring-fuchsia-500/25' },
    laptop: { label: 'Laptop', classes: 'bg-sky-500/10 text-sky-300 ring-sky-500/25' },
    smart_tv: { label: 'Smart TV', classes: 'bg-amber-500/10 text-amber-300 ring-amber-500/25' },
    smartwatch: { label: 'Smartwatch', classes: 'bg-violet-500/10 text-violet-300 ring-violet-500/25' },
};

const SPEC_LABELS: Record<string, string> = {
    sensor_ram: 'Sensor / RAM',
    storage_cards: 'Storage',
    graphics_engine: 'Graphics / Engine',
    key_specs: 'Key Specs',
    camera_description: 'Description',
    memory_ram: 'Memory (RAM)',
    storage_ssd: 'Storage (SSD)',
    graphics_card: 'Graphics Card',
    core_architecture: 'Core Architecture',
    screen_size: 'Screen Size',
    resolution_standard: 'Resolution',
    display_tech_specialty: 'Display Tech',
    memory_and_storage: 'Memory & Storage',
    graphics_coprocessor: 'Graphics Coprocessor',
    sensor_array: 'Sensors & Connectivity',
    architectural_description: 'Architecture & Features',
};

const EXTRACTED_LABELS: Record<string, string> = {
    category: 'Category',
    brand_or_make: 'Brand / Make',
    product_name: 'Product',
    price: 'Price',
    ...SPEC_LABELS,
};

// ---------------------------------------------------------------------------
// Display-only text polish.
//
// ragwire's metadata extractor lowercases every string it stores (not
// configurable — see backend/rag_engine.py's _titleize, which fixes
// brand/product name up server-side). Spec values stay raw from the API, so
// this does the same job client-side: title-case short spec values, upper-
// case known tech acronyms/units, and sentence-case the long free-text
// fields (camera/architecture descriptions) instead of title-casing full
// prose. Purely cosmetic — the underlying data driving search/filters is
// never touched.
// ---------------------------------------------------------------------------

const ACRONYMS: Record<string, string> = {
    ai: 'AI', amd: 'AMD', asic: 'ASIC', asus: 'ASUS', cmos: 'CMOS', dslr: 'DSLR',
    fhd: 'FHD', gb: 'GB', gps: 'GPS', gpu: 'GPU', hd: 'HD', hdmi: 'HDMI', hp: 'HP',
    ip: 'IP', ips: 'IPS', ir: 'IR', kb: 'KB', led: 'LED', lg: 'LG', lte: 'LTE',
    mah: 'mAh', mb: 'MB', msi: 'MSI', nfc: 'NFC', oled: 'OLED', os: 'OS',
    amoled: 'AMOLED', qled: 'QLED', qhd: 'QHD', wqhd: 'WQHD', ram: 'RAM',
    rom: 'ROM', rog: 'ROG', rtx: 'RTX', gtx: 'GTX', sd: 'SD', sim: 'SIM',
    soc: 'SoC', ssd: 'SSD', hdd: 'HDD', tb: 'TB', tcl: 'TCL', tgp: 'TGP',
    tof: 'ToF', tv: 'TV', uhd: 'UHD', usb: 'USB', usd: 'USD', vpro: 'vPro',
    zte: 'ZTE', ppg: 'PPG', ecg: 'ECG', spo: 'SpO', gnss: 'GNSS', nvme: 'NVMe',
    pcie: 'PCIe', ddr: 'DDR', lpddr: 'LPDDR', nvidia: 'NVIDIA', ghz: 'GHz',
    mhz: 'MHz', mp: 'MP',
};

const BRAND_OVERRIDES: Record<string, string> = {
    gopro: 'GoPro', oneplus: 'OnePlus', playstation: 'PlayStation',
    geforce: 'GeForce', iphone: 'iPhone', ipad: 'iPad', imac: 'iMac',
    macbook: 'MacBook', airpods: 'AirPods', ryzen: 'Ryzen', radeon: 'Radeon',
    kirin: 'Kirin', exmor: 'Exmor', bionz: 'BIONZ', snapdragon: 'Snapdragon',
};

function fixRun(run: string): string {
    const lower = run.toLowerCase();
    if (BRAND_OVERRIDES[lower]) return BRAND_OVERRIDES[lower];
    if (ACRONYMS[lower]) return ACRONYMS[lower];
    return run.charAt(0).toUpperCase() + run.slice(1).toLowerCase();
}

/** Title-cases short spec values, fixing known acronyms/brand names. */
function titleCase(text: string): string {
    return text
        .replace(/\bwi-?fi\b/gi, 'Wi-Fi')
        .replace(/\b(\d+)k\b/gi, '$1K')
        .replace(/[A-Za-z]+/g, fixRun);
}

/** Sentence-cases long free-text values instead of title-casing full prose. */
function sentenceCase(text: string): string {
    const normalized = text
        .replace(/\s*\n+\s*/g, ' ')
        .trim()
        .replace(/\bwi-?fi\b/gi, 'Wi-Fi')
        .replace(/\b(\d+)k\b/gi, '$1K');
    const withAcronyms = normalized.replace(/[A-Za-z]+/g, (run) => {
        const lower = run.toLowerCase();
        if (BRAND_OVERRIDES[lower]) return BRAND_OVERRIDES[lower];
        if (ACRONYMS[lower]) return ACRONYMS[lower];
        return run;
    });
    return withAcronyms.replace(/(^\s*[a-z])|([.!?]\s+)([a-z])/g, (_m, p1, p2, p3) =>
        p1 ? p1.toUpperCase() : `${p2}${p3.toUpperCase()}`
    );
}

/** A spec value that's long or contains an embedded newline (real catalog
 * data mixes several facts into one field, e.g. core_architecture) reads
 * as a sentence, not a label — render it as a paragraph, not a pill. */
function isLongValue(value: string): boolean {
    return value.length > 46 || value.includes('\n');
}

function displayValue(value: string): string {
    return isLongValue(value) ? sentenceCase(value) : titleCase(value);
}

function ProductCard({ product }: { product: Product }) {
    const meta = product.category ? CATEGORY_META[product.category] : undefined;
    const specEntries = Object.entries(product.specs || {});
    const pillSpecs = specEntries.filter(([, value]) => !isLongValue(value));
    const longSpecs = specEntries.filter(([, value]) => isLongValue(value));

    return (
        <div className="w-full rounded-xl border border-white/10 bg-white/[0.03] p-3 shadow-sm">
            <div className="flex items-start justify-between gap-2">
                <p className="text-sm font-semibold leading-snug text-slate-100">
                    {product.product_name || 'Unknown product'}
                </p>
                {meta && (
                    <span className={`flex-shrink-0 rounded-full px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wide ring-1 ring-inset ${meta.classes}`}>
                        {meta.label}
                    </span>
                )}
            </div>

            {product.brand_or_make && (
                <p className="mt-1 text-xs text-slate-400">{product.brand_or_make}</p>
            )}

            <div className="mt-2 flex flex-wrap gap-1.5">
                {product.price && (
                    <span className="rounded-full bg-emerald-500/10 px-2 py-0.5 text-[11px] font-semibold text-emerald-300 ring-1 ring-inset ring-emerald-500/25">
                        {product.price}
                    </span>
                )}
                {pillSpecs.map(([field, value]) => (
                    <span key={field} className="rounded-full bg-indigo-500/10 px-2 py-0.5 text-[11px] font-medium text-indigo-300 ring-1 ring-inset ring-indigo-500/25">
                        {(SPEC_LABELS[field] || field) + ': ' + titleCase(value)}
                    </span>
                ))}
            </div>

            {longSpecs.map(([field, value]) => (
                <p key={field} className="mt-2 text-xs leading-relaxed text-slate-400">
                    <span className="font-medium text-slate-300">{SPEC_LABELS[field] || field}: </span>
                    {sentenceCase(value)}
                </p>
            ))}
        </div>
    );
}

function renderInline(text: string, keyPrefix: string) {
    // Splits on **bold** segments — the only inline markdown the assistant uses.
    const parts = text.split(/\*\*(.+?)\*\*/g);
    return parts.map((part, i) =>
        i % 2 === 1 ? <strong key={`${keyPrefix}-${i}`}>{part}</strong> : <span key={`${keyPrefix}-${i}`}>{part}</span>
    );
}

/** Minimal markdown-lite renderer: groups "- "/"* " bullet lines into a list,
 * renders **bold** inline, everything else as plain paragraphs. The assistant
 * sometimes formats its short reply this way even though the product cards
 * already carry the detail — this just keeps that readable instead of
 * showing raw asterisks and dashes. */
function FormattedText({ text }: { text: string }) {
    const lines = text.split('\n');
    const blocks: { type: 'p' | 'ul'; lines: string[] }[] = [];

    for (const rawLine of lines) {
        const line = rawLine.trim();
        const isBullet = line.startsWith('- ') || line.startsWith('* ');
        if (!line) continue;
        const content = isBullet ? line.slice(2) : line;
        const last = blocks[blocks.length - 1];
        const kind = isBullet ? 'ul' : 'p';
        if (last && last.type === kind && kind === 'ul') {
            last.lines.push(content);
        } else {
            blocks.push({ type: kind, lines: [content] });
        }
    }

    return (
        <div className="flex flex-col gap-1.5">
            {blocks.map((block, i) =>
                block.type === 'ul' ? (
                    <ul key={i} className="list-disc space-y-0.5 pl-4">
                        {block.lines.map((line, j) => (
                            <li key={j}>{renderInline(line, `${i}-${j}`)}</li>
                        ))}
                    </ul>
                ) : (
                    <p key={i}>{renderInline(block.lines[0], `${i}`)}</p>
                )
            )}
        </div>
    );
}

function ThinkingIndicator({ stage }: { stage: string }) {
    return (
        <div className="animate-message-in flex items-end gap-2.5 justify-start">
            <div className="flex h-7 w-7 flex-shrink-0 items-center justify-center rounded-full bg-gradient-to-br from-indigo-500 to-sky-500 text-white">
                <Sparkles className="h-3.5 w-3.5" />
            </div>
            <div className="rounded-2xl rounded-bl-md border border-white/10 bg-gradient-to-r from-slate-900 via-indigo-950/50 to-slate-900 bg-[length:200%_100%] px-4 py-2.5 shadow-sm animate-shimmer">
                <p key={stage} className="animate-stage-fade flex items-center gap-2 text-xs font-medium text-slate-300">
                    <span className="flex gap-1">
                        <span className="h-1.5 w-1.5 animate-bounce rounded-full bg-indigo-400" />
                        <span className="delay-100 h-1.5 w-1.5 animate-bounce rounded-full bg-indigo-400" />
                        <span className="delay-200 h-1.5 w-1.5 animate-bounce rounded-full bg-indigo-400" />
                    </span>
                    {stage}
                </p>
            </div>
        </div>
    );
}

export default function GadgetHubAdvisor() {
    const [messages, setMessages] = useState<Message[]>([]);
    const [input, setInput] = useState('');
    const [isLoading, setIsLoading] = useState(false);
    const [thinkingStage, setThinkingStage] = useState<string>('Thinking through your question...');
    const [sessionId, setSessionId] = useState<string>('');
    const [streamingId, setStreamingId] = useState<string | null>(null);
    const messagesContainerRef = useRef<HTMLDivElement>(null);
    const inputRef = useRef<HTMLInputElement>(null);
    const fileInputRef = useRef<HTMLInputElement>(null);

    const scrollToBottom = () => {
        const el = messagesContainerRef.current;
        if (!el) return;
        el.scrollTo({ top: el.scrollHeight, behavior: 'smooth' });
    };

    useEffect(() => {
        scrollToBottom();
    }, [messages, isLoading]);

    const appendMessage = (msg: Message) => setMessages(prev => [...prev, msg]);

    const startNewChat = () => {
        if (isLoading) return;
        setMessages([]);
        setSessionId('');
        setStreamingId(null);
        setInput('');
        inputRef.current?.focus();
    };

    const sendMessage = async (text?: string) => {
        const content = (text ?? input).trim();
        if (!content || isLoading) return;

        appendMessage({ id: crypto.randomUUID(), role: 'user', content, timestamp: new Date() });
        setInput('');
        setIsLoading(true);
        setThinkingStage('Thinking through your question...');

        try {
            const response = await fetch(`${API_URL}/chat`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json', 'X-API-Key': API_KEY },
                body: JSON.stringify({ message: content, session_id: sessionId || undefined }),
            });

            if (!response.ok || !response.body) throw new Error('Failed to send message');

            const reader = response.body.getReader();
            const decoder = new TextDecoder();
            let buffer = '';

            const assistantId = crypto.randomUUID();
            let streamedContent = '';
            let assistantMessageStarted = false;

            while (true) {
                const { done, value } = await reader.read();
                if (done) break;
                buffer += decoder.decode(value, { stream: true });
                const chunks = buffer.split('\n\n');
                buffer = chunks.pop() ?? '';

                for (const chunk of chunks) {
                    const line = chunk.trim();
                    if (!line.startsWith('data:')) continue;
                    const evt = JSON.parse(line.slice(5).trim());

                    if (evt.type === 'status') {
                        setThinkingStage(evt.stage);
                    } else if (evt.type === 'token') {
                        streamedContent += evt.content;
                        if (!assistantMessageStarted) {
                            assistantMessageStarted = true;
                            setStreamingId(assistantId);
                            appendMessage({
                                id: assistantId,
                                role: 'assistant',
                                content: streamedContent,
                                timestamp: new Date(),
                            });
                        } else {
                            setMessages(prev =>
                                prev.map(m => (m.id === assistantId ? { ...m, content: streamedContent } : m))
                            );
                        }
                    } else if (evt.type === 'final') {
                        if (!sessionId && evt.session_id) setSessionId(evt.session_id);
                        setStreamingId(null);
                        if (assistantMessageStarted) {
                            setMessages(prev =>
                                prev.map(m =>
                                    m.id === assistantId ? { ...m, content: evt.response, products: evt.products } : m
                                )
                            );
                        } else {
                            appendMessage({
                                id: assistantId,
                                role: 'assistant',
                                content: evt.response,
                                products: evt.products,
                                timestamp: new Date(),
                            });
                        }
                    } else if (evt.type === 'error') {
                        setStreamingId(null);
                        appendMessage({
                            id: crypto.randomUUID(),
                            role: 'assistant',
                            content: `Sorry, something went wrong: ${evt.message}`,
                            timestamp: new Date(),
                        });
                    }
                }
            }
        } catch (error) {
            console.error('Error:', error);
            appendMessage({
                id: crypto.randomUUID(),
                role: 'assistant',
                content: 'Sorry, I encountered an error reaching the advisor. Please try again.',
                timestamp: new Date(),
            });
        } finally {
            setIsLoading(false);
            setStreamingId(null);
            inputRef.current?.focus();
        }
    };

    const uploadFile = async (file: File) => {
        appendMessage({
            id: crypto.randomUUID(),
            role: 'user',
            content: `Uploaded: ${file.name}`,
            timestamp: new Date(),
        });
        setIsLoading(true);
        setThinkingStage('Scanning your file...');

        try {
            const formData = new FormData();
            formData.append('file', file);
            if (sessionId) formData.append('session_id', sessionId);

            setThinkingStage('Extracting product details...');
            const response = await fetch(`${API_URL}/upload`, {
                method: 'POST',
                headers: { 'X-API-Key': API_KEY },
                body: formData,
            });

            const data = await response.json();

            if (!data.success) {
                appendMessage({
                    id: crypto.randomUUID(),
                    role: 'assistant',
                    content: `I couldn't read that file: ${data.error}`,
                    timestamp: new Date(),
                });
                return;
            }

            if (!sessionId && data.session_id) setSessionId(data.session_id);

            const extracted = data.extracted as Record<string, string | null>;
            const lines = Object.entries(extracted)
                .filter(([, v]) => v)
                .map(([k, v]) => {
                    const value = k === 'category'
                        ? (CATEGORY_META[v as string]?.label ?? titleCase(v as string))
                        : (k === 'product_name' || k === 'brand_or_make' || k === 'price')
                            ? v
                            : displayValue(v as string);
                    return `${EXTRACTED_LABELS[k] || k}: ${value}`;
                });

            const scannedMessage = data.message || `Scanned successfully: ${file.name}`;
            const summary = `**${scannedMessage}**\nHere's what I found in your file:\n${lines.join('\n')}` +
                (data.alternatives?.length ? '\n\nHere are some catalog alternatives worth a look:' : '\n\nI could not find a close match in the catalog for that one.');

            appendMessage({
                id: crypto.randomUUID(),
                role: 'assistant',
                content: summary,
                products: data.alternatives,
                timestamp: new Date(),
            });
        } catch (error) {
            console.error('Upload error:', error);
            appendMessage({
                id: crypto.randomUUID(),
                role: 'assistant',
                content: 'Sorry, I could not analyze that file. Please try again.',
                timestamp: new Date(),
            });
        } finally {
            setIsLoading(false);
        }
    };

    const handleFileSelected = (e: React.ChangeEvent<HTMLInputElement>) => {
        const file = e.target.files?.[0];
        e.target.value = '';
        if (!file) return;
        if (file.type !== 'application/pdf') {
            appendMessage({
                id: crypto.randomUUID(),
                role: 'assistant',
                content: 'Please upload a PDF file.',
                timestamp: new Date(),
            });
            return;
        }
        uploadFile(file);
    };

    const handleKeyPress = (e: React.KeyboardEvent) => {
        if (e.key === 'Enter' && !e.shiftKey) {
            e.preventDefault();
            sendMessage();
        }
    };

    return (
        <div className="flex h-full w-full flex-col overflow-hidden bg-slate-950">
            {/* Header */}
            <header className="flex flex-shrink-0 items-center gap-3 border-b border-white/10 bg-slate-950/80 px-4 py-3 backdrop-blur sm:px-6">
                <div className="relative flex-shrink-0">
                    <div className="flex h-10 w-10 items-center justify-center rounded-full bg-gradient-to-br from-indigo-500 to-sky-500 text-white shadow-lg shadow-indigo-950/50">
                        <Sparkles className="h-5 w-5" />
                    </div>
                    <span className="absolute -bottom-0.5 -right-0.5 block h-3 w-3 rounded-full border-2 border-slate-950 bg-emerald-400" />
                </div>
                <div className="min-w-0 flex-1">
                    <h1 className="truncate text-base font-semibold text-white">
                        GadgetHub &middot; Product Advisor
                    </h1>
                    <p className="truncate text-xs text-slate-400">
                        Online &middot; Ask about smartwatches, TVs, laptops &amp; cameras
                    </p>
                </div>
                <button
                    type="button"
                    onClick={startNewChat}
                    disabled={isLoading || messages.length === 0}
                    aria-label="Start a new chat"
                    className="flex flex-shrink-0 items-center gap-1.5 rounded-full border border-white/10 bg-white/5 px-3 py-1.5 text-xs font-medium text-slate-300 transition-colors hover:border-indigo-400/40 hover:bg-indigo-500/10 hover:text-indigo-300 disabled:cursor-not-allowed disabled:opacity-40"
                >
                    <PlusCircle className="h-3.5 w-3.5" />
                    <span className="hidden sm:inline">New chat</span>
                </button>
            </header>

            {/* Messages */}
            <div
                ref={messagesContainerRef}
                className="scrollbar-thin flex-1 overflow-y-auto px-4 py-6 sm:px-6"
            >
                <div className="mx-auto flex w-full max-w-2xl flex-col gap-4">
                    {messages.length === 0 && (
                        <div className="flex flex-1 flex-col items-center justify-center px-4 py-10 text-center">
                            <div className="mb-4 flex h-14 w-14 items-center justify-center rounded-2xl bg-indigo-500/10 text-indigo-300 ring-1 ring-inset ring-indigo-500/25">
                                <Sparkles className="h-6 w-6" />
                            </div>
                            <p className="text-sm font-medium text-slate-100">
                                Hi, I&apos;m your gadget shop advisor.
                            </p>
                            <p className="mt-1 max-w-xs text-sm text-slate-400">
                                Tell me what you need, a problem you&apos;re having, or upload a
                                product spec sheet &mdash; try one of these to get started.
                            </p>
                            <div className="mt-5 flex w-full max-w-sm flex-col gap-2">
                                {SUGGESTIONS.map((suggestion) => (
                                    <button
                                        key={suggestion}
                                        type="button"
                                        onClick={() =>
                                            suggestion.startsWith('Upload')
                                                ? fileInputRef.current?.click()
                                                : sendMessage(suggestion)
                                        }
                                        className="rounded-xl border border-white/10 bg-white/[0.03] px-4 py-2.5 text-left text-sm text-slate-300 transition-colors hover:border-indigo-400/40 hover:bg-indigo-500/10 hover:text-indigo-200"
                                    >
                                        {suggestion}
                                    </button>
                                ))}
                            </div>
                        </div>
                    )}

                    {messages.map((message) => (
                        <div
                            key={message.id}
                            className={`animate-message-in flex items-end gap-2.5 ${
                                message.role === 'user' ? 'justify-end' : 'justify-start'
                            }`}
                        >
                            {message.role === 'assistant' && (
                                <div className="flex h-7 w-7 flex-shrink-0 items-center justify-center rounded-full bg-gradient-to-br from-indigo-500 to-sky-500 text-white">
                                    <Sparkles className="h-3.5 w-3.5" />
                                </div>
                            )}

                            <div
                                className={`max-w-[85%] rounded-2xl px-4 py-2.5 text-sm leading-relaxed shadow-sm sm:max-w-[80%] ${
                                    message.role === 'user'
                                        ? 'rounded-br-md bg-gradient-to-br from-indigo-500 to-sky-500 text-white'
                                        : 'rounded-bl-md border border-white/10 bg-white/[0.04] text-slate-100'
                                }`}
                            >
                                {message.role === 'assistant' ? (
                                    <FormattedText text={message.content} />
                                ) : (
                                    <p className="whitespace-pre-wrap">{message.content}</p>
                                )}

                                {message.products && message.products.length > 0 && (
                                    <div className="mt-3 flex flex-col gap-2">
                                        {message.products.map((product, idx) => (
                                            <ProductCard key={idx} product={product} />
                                        ))}
                                    </div>
                                )}

                                <p
                                    className={`mt-1 text-[10px] ${
                                        message.role === 'user' ? 'text-indigo-50/80' : 'text-slate-500'
                                    }`}
                                >
                                    {message.timestamp.toLocaleTimeString([], {
                                        hour: '2-digit',
                                        minute: '2-digit',
                                    })}
                                </p>
                            </div>

                            {message.role === 'user' && (
                                <div className="flex h-7 w-7 flex-shrink-0 items-center justify-center rounded-full border border-white/10 bg-slate-800 text-slate-200">
                                    <User className="h-3.5 w-3.5" />
                                </div>
                            )}
                        </div>
                    ))}

                    {isLoading && !streamingId && <ThinkingIndicator stage={thinkingStage} />}
                </div>
            </div>

            {/* Input */}
            <div className="flex-shrink-0 border-t border-white/10 bg-slate-950 px-4 py-3 sm:px-6">
                <div className="mx-auto w-full max-w-2xl">
                    <div className="flex items-center gap-2 rounded-full border border-white/10 bg-white/[0.04] p-1.5 pl-2 transition-colors focus-within:border-indigo-400/50 focus-within:bg-white/[0.07] focus-within:ring-2 focus-within:ring-indigo-500/20">
                        <input
                            ref={fileInputRef}
                            type="file"
                            accept="application/pdf"
                            className="hidden"
                            onChange={handleFileSelected}
                        />
                        <button
                            type="button"
                            onClick={() => fileInputRef.current?.click()}
                            disabled={isLoading}
                            aria-label="Upload a product spec sheet PDF"
                            className="flex h-9 w-9 flex-shrink-0 items-center justify-center rounded-full text-slate-500 transition-colors hover:bg-white/5 hover:text-indigo-300 disabled:cursor-not-allowed disabled:opacity-40"
                        >
                            <Paperclip className="h-4 w-4" />
                        </button>
                        <input
                            ref={inputRef}
                            type="text"
                            value={input}
                            onChange={(e) => setInput(e.target.value)}
                            onKeyDown={handleKeyPress}
                            placeholder="Ask about gadgets, or attach a spec sheet..."
                            className="flex-1 bg-transparent text-sm text-slate-100 placeholder:text-slate-500 focus:outline-none"
                            disabled={isLoading}
                        />
                        <button
                            onClick={() => sendMessage()}
                            disabled={!input.trim() || isLoading}
                            aria-label="Send message"
                            className="flex h-9 w-9 flex-shrink-0 items-center justify-center rounded-full bg-gradient-to-br from-indigo-500 to-sky-500 text-white shadow-sm transition-all hover:shadow-md hover:shadow-indigo-950/50 disabled:cursor-not-allowed disabled:opacity-40 disabled:shadow-none"
                        >
                            <Send className="h-4 w-4" />
                        </button>
                    </div>
                    <p className="mt-2 flex items-center justify-center gap-1.5 text-center text-[11px] leading-snug text-slate-500">
                        <Info className="h-3 w-3 flex-shrink-0" />
                        AI-generated from our live catalog. Always retrieved, never invented.
                    </p>
                </div>
            </div>
        </div>
    );
}
