import Foundation

public struct MobileClientHTML {
    public static func page(
        hostLangCode: String = "en",
        hostLangName: String = "English",
        callerLangCode: String = "es",
        callerLangName: String = "Spanish"
    ) -> String {
        let languagesJson = SupportedLanguages.jsonArrayString()
        
        return """
        <!DOCTYPE html>
        <html lang="\(callerLangCode)">
        <head>
          <meta charset="UTF-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover">
          <meta name="apple-mobile-web-app-capable" content="yes">
          <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
          <title>Live Subtitles</title>
          <style>
            :root {
              --bg-dark: #06090e;
              --card-glass: rgba(18, 26, 36, 0.78);
              --card-border: rgba(255, 255, 255, 0.12);
              --neon-green: #10b981;
              --neon-cyan: #06b6d4;
              --neon-blue: #3b82f6;
              --text-white: #ffffff;
              --text-dim: rgba(255, 255, 255, 0.55);
            }
            * { box-sizing: border-box; margin: 0; padding: 0; -webkit-tap-highlight-color: transparent; }
            body {
              background: radial-gradient(circle at 50% -10%, rgba(16, 185, 129, 0.14) 0%, rgba(6, 182, 212, 0.08) 35%, var(--bg-dark) 80%);
              background-color: var(--bg-dark);
              color: var(--text-white);
              font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "SF Pro Text", "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
              min-height: 100vh;
              display: flex;
              flex-direction: column;
              padding: 16px;
              padding-top: max(16px, env(safe-area-inset-top));
              padding-bottom: max(16px, env(safe-area-inset-bottom));
              overflow-x: hidden;
            }

            /* --- Top Frosted Glass Header --- */
            header.glass-header {
              background: var(--card-glass);
              border: 1px solid var(--card-border);
              border-radius: 18px;
              backdrop-filter: blur(25px) saturate(180%);
              -webkit-backdrop-filter: blur(25px) saturate(180%);
              padding: 12px 14px;
              display: flex;
              justify-content: space-between;
              align-items: center;
              gap: 10px;
              box-shadow: 0 8px 24px rgba(0, 0, 0, 0.45);
            }
            .header-left {
              display: flex;
              flex-direction: column;
              gap: 6px;
              min-width: 0;
              flex: 1;
            }
            .status-pill {
              display: flex;
              align-items: center;
              gap: 8px;
            }
            .status-beacon {
              width: 9px;
              height: 9px;
              min-width: 9px;
              background: var(--neon-green);
              border-radius: 50%;
              box-shadow: 0 0 12px var(--neon-green), 0 0 4px var(--neon-green);
              animation: beaconPulse 2s infinite ease-in-out;
            }
            @keyframes beaconPulse {
              0%, 100% { transform: scale(1); opacity: 1; }
              50% { transform: scale(1.25); opacity: 0.75; }
            }
            .status-title {
              font-size: 11.5px;
              font-weight: 800;
              letter-spacing: 0.8px;
              text-transform: uppercase;
              color: var(--neon-green);
            }
            .lang-pill-row {
              display: flex;
              align-items: center;
              gap: 6px;
              background: rgba(255, 255, 255, 0.06);
              border: 1px solid rgba(255, 255, 255, 0.14);
              border-radius: 10px;
              padding: 4px 10px;
              max-width: 260px;
            }
            .translating-label {
              font-size: 11px;
              color: var(--text-dim);
              font-weight: 600;
              white-space: nowrap;
            }
            .lang-pill-select {
              background: transparent;
              border: none;
              color: #ffffff;
              font-size: 12px;
              font-weight: 700;
              outline: none;
              cursor: pointer;
              width: 100%;
            }
            .lang-pill-select option {
              background: #0d1520;
              color: #fff;
            }
            
            /* Modern PiP Button */
            .header-right {
              display: flex;
              align-items: center;
              gap: 8px;
              flex-shrink: 0;
            }
            .btn-pip-modern {
              background: rgba(255, 255, 255, 0.08);
              border: 1px solid rgba(255, 255, 255, 0.18);
              border-radius: 14px;
              color: #ffffff;
              padding: 8px 14px;
              display: flex;
              flex-direction: column;
              align-items: center;
              justify-content: center;
              gap: 2px;
              cursor: pointer;
              transition: all 0.2s cubic-bezier(0.4, 0, 0.2, 1);
            }
            .btn-pip-modern:active {
              background: rgba(16, 185, 129, 0.25);
              border-color: var(--neon-green);
              transform: scale(0.96);
            }
            .pip-icon-svg {
              width: 18px;
              height: 18px;
              fill: currentColor;
            }
            .pip-label-text {
              font-size: 10px;
              font-weight: 800;
              letter-spacing: 0.5px;
            }

            /* --- Main Live Subtitle Card --- */
            main {
              flex: 1;
              display: flex;
              flex-direction: column;
              justify-content: center;
              gap: 16px;
              margin-top: 14px;
            }
            .caption-card-modern {
              background: var(--card-glass);
              border: 1px solid var(--card-border);
              border-radius: 24px;
              padding: 24px 20px;
              box-shadow: 0 16px 48px rgba(0, 0, 0, 0.65);
              backdrop-filter: blur(30px) saturate(190%);
              -webkit-backdrop-filter: blur(30px) saturate(190%);
              display: flex;
              flex-direction: column;
              min-height: 300px;
              position: relative;
            }
            .speaker-header-row {
              display: flex;
              align-items: center;
              gap: 8px;
              margin-bottom: 16px;
            }
            .speaker-mic-badge {
              display: flex;
              align-items: center;
              gap: 6px;
              background: rgba(16, 185, 129, 0.12);
              border: 1px solid rgba(16, 185, 129, 0.35);
              border-radius: 8px;
              padding: 4px 10px;
            }
            .mic-svg {
              width: 13px;
              height: 13px;
              fill: var(--neon-green);
            }
            .speaker-title-text {
              font-size: 11px;
              font-weight: 800;
              letter-spacing: 0.6px;
              text-transform: uppercase;
              color: var(--neon-green);
            }
            .lang-route-tag {
              font-size: 11px;
              font-weight: 700;
              color: var(--text-dim);
              letter-spacing: 0.5px;
            }

            .subtitles-body {
              flex: 1;
              display: flex;
              flex-direction: column;
              justify-content: center;
            }
            .original-sub {
              font-size: 14px;
              color: var(--text-dim);
              font-style: italic;
              margin-bottom: 8px;
              line-height: 1.4;
              word-break: break-word;
            }
            .translated-sub {
              font-size: 28px;
              font-weight: 700;
              line-height: 1.34;
              color: #ffffff;
              word-break: break-word;
              text-shadow: 0 2px 14px rgba(0, 0, 0, 0.8);
              transition: font-size 0.2s ease;
            }

            /* --- Glowing Voice Pulse Orb --- */
            .voice-orb-container {
              display: flex;
              align-items: center;
              justify-content: center;
              margin-top: 24px;
              position: relative;
              height: 84px;
            }
            .pulse-ring {
              position: absolute;
              width: 72px;
              height: 72px;
              border-radius: 50%;
              border: 1px solid rgba(6, 182, 212, 0.35);
              opacity: 0;
              pointer-events: none;
            }
            .voice-orb-container.speaking .pulse-ring.ring-1 {
              animation: ringPulse 2s infinite ease-out;
            }
            .voice-orb-container.speaking .pulse-ring.ring-2 {
              animation: ringPulse 2s infinite ease-out 0.6s;
            }
            @keyframes ringPulse {
              0% { transform: scale(0.9); opacity: 0.8; border-color: rgba(6, 182, 212, 0.6); }
              100% { transform: scale(1.6); opacity: 0; border-color: rgba(16, 185, 129, 0); }
            }
            .voice-orb {
              width: 66px;
              height: 66px;
              border-radius: 50%;
              background: radial-gradient(circle, rgba(6, 182, 212, 0.25) 0%, rgba(18, 26, 36, 0.85) 80%);
              border: 2px solid var(--neon-cyan);
              box-shadow: 0 0 20px rgba(6, 182, 212, 0.45), inset 0 0 12px rgba(6, 182, 212, 0.25);
              display: flex;
              align-items: center;
              justify-content: center;
              position: relative;
              z-index: 2;
              transition: all 0.3s ease;
            }
            .voice-orb-container.speaking .voice-orb {
              border-color: var(--neon-green);
              box-shadow: 0 0 25px rgba(16, 185, 129, 0.6), inset 0 0 15px rgba(16, 185, 129, 0.35);
            }
            .equalizer-bars {
              display: flex;
              align-items: center;
              gap: 3.5px;
              height: 28px;
            }
            .equalizer-bars .bar {
              width: 3.5px;
              height: 6px;
              background: var(--neon-cyan);
              border-radius: 3px;
              transition: height 0.15s ease, background 0.3s ease;
            }
            .voice-orb-container.speaking .equalizer-bars .bar {
              background: var(--neon-green);
            }
            .voice-orb-container.speaking .bar-1 { animation: eqBounce 0.8s infinite alternate ease-in-out; }
            .voice-orb-container.speaking .bar-2 { animation: eqBounce 0.6s infinite alternate ease-in-out 0.1s; }
            .voice-orb-container.speaking .bar-3 { animation: eqBounce 0.9s infinite alternate ease-in-out 0.2s; }
            .voice-orb-container.speaking .bar-4 { animation: eqBounce 0.7s infinite alternate ease-in-out 0.15s; }
            .voice-orb-container.speaking .bar-5 { animation: eqBounce 0.85s infinite alternate ease-in-out 0.05s; }
            @keyframes eqBounce {
              0% { height: 6px; }
              100% { height: 26px; }
            }

            /* --- Bottom Floating Dock --- */
            footer.bottom-dock {
              background: var(--card-glass);
              border: 1px solid var(--card-border);
              border-radius: 18px;
              backdrop-filter: blur(25px) saturate(180%);
              -webkit-backdrop-filter: blur(25px) saturate(180%);
              padding: 10px 14px;
              display: flex;
              justify-content: space-between;
              align-items: center;
              gap: 10px;
              margin-top: 14px;
              box-shadow: 0 10px 30px rgba(0, 0, 0, 0.55);
            }
            .font-controls {
              display: flex;
              gap: 6px;
            }
            .btn-dock {
              background: rgba(255, 255, 255, 0.08);
              border: 1px solid rgba(255, 255, 255, 0.16);
              border-radius: 10px;
              color: #ffffff;
              width: 38px;
              height: 36px;
              font-size: 13px;
              font-weight: 700;
              cursor: pointer;
              display: flex;
              align-items: center;
              justify-content: center;
              transition: all 0.2s;
            }
            .btn-dock:active {
              background: rgba(255, 255, 255, 0.2);
              transform: scale(0.95);
            }
            .btn-copy-transcript {
              flex: 1;
              background: rgba(255, 255, 255, 0.08);
              border: 1px solid rgba(255, 255, 255, 0.16);
              border-radius: 10px;
              color: #ffffff;
              height: 36px;
              font-size: 13px;
              font-weight: 700;
              cursor: pointer;
              display: flex;
              align-items: center;
              justify-content: center;
              gap: 6px;
              transition: all 0.2s;
            }
            .btn-copy-transcript:active {
              background: rgba(16, 185, 129, 0.25);
              border-color: var(--neon-green);
              color: var(--neon-green);
              transform: scale(0.98);
            }

            /* Floating Toast */
            .toast {
              position: fixed;
              bottom: 84px;
              left: 50%;
              transform: translateX(-50%);
              background: rgba(16, 185, 129, 0.95);
              color: #04100c;
              padding: 9px 20px;
              border-radius: 20px;
              font-size: 13px;
              font-weight: 800;
              box-shadow: 0 6px 20px rgba(0, 0, 0, 0.6);
              opacity: 0;
              pointer-events: none;
              transition: opacity 0.3s ease;
              z-index: 9999;
            }
            .toast.show {
              opacity: 1;
            }

            #pipCanvas {
              position: fixed;
              left: -9999px;
              top: -9999px;
              width: 640px;
              height: 220px;
              opacity: 0;
              pointer-events: none;
            }
            #pipVideo {
              position: fixed;
              left: -9999px;
              top: -9999px;
              width: 320px;
              height: 180px;
              opacity: 0.01;
              pointer-events: none;
            }
          </style>
        </head>
        <body>
          <!-- Top Frosted Glass Header -->
          <header class="glass-header">
            <div class="header-left">
              <div class="status-pill">
                <div class="status-beacon" id="statusDot"></div>
                <span class="status-title" id="statusText">LIVE STREAM CONNECTED</span>
              </div>
              <div class="lang-pill-row">
                <span class="translating-label" id="translatingLabel">Translating to:</span>
                <select id="callerLangSelect" class="lang-pill-select" onchange="onLanguageSelectionChanged()"></select>
              </div>
            </div>
            <div class="header-right">
              <button class="btn-pip-modern" id="pipBtn" onclick="togglePiP()" title="Float Subtitles over Calls">
                <svg class="pip-icon-svg" viewBox="0 0 24 24">
                  <path d="M19 11h-8v6h8v-6zm4 8V4.98C23 3.88 22.1 3 21 3H3c-1.1 0-2 .88-2 1.98V19c0 1.1.9 2 2 2h18c1.1 0 2-.9 2-2zm-2 .02H3V4.97h18v14.05z"/>
                </svg>
                <span class="pip-label-text">PiP</span>
              </button>
            </div>
          </header>

          <!-- Main Live Subtitle Card -->
          <main>
            <div class="caption-card-modern">
              <div class="speaker-header-row">
                <div class="speaker-mic-badge">
                  <svg class="mic-svg" viewBox="0 0 24 24">
                    <path d="M12 14c1.66 0 3-1.34 3-3V5c0-1.66-1.34-3-3-3S9 3.34 9 5v6c0 1.66 1.34 3 3 3z"/>
                    <path d="M17 11c0 2.76-2.24 5-5 5s-5-2.24-5-5H5c0 3.53 2.61 6.43 6 6.92V21h2v-3.08c3.39-.49 6-3.39 6-6.92h-2z"/>
                  </svg>
                  <span class="speaker-title-text" id="speakerLabel">SPEAKER</span>
                </div>
                <div class="lang-route-tag" id="langIndicator">\(hostLangCode.uppercased()) ➔ \(callerLangCode.uppercased())</div>
              </div>

              <div class="subtitles-body">
                <div class="original-sub" id="originalText"></div>
                <div class="translated-sub" id="translatedText">Listening for live speech in call...</div>
              </div>

              <!-- Glowing Voice Pulse Orb -->
              <div class="voice-orb-container" id="voiceOrb">
                <div class="pulse-ring ring-1"></div>
                <div class="pulse-ring ring-2"></div>
                <div class="voice-orb">
                  <div class="equalizer-bars">
                    <span class="bar bar-1"></span>
                    <span class="bar bar-2"></span>
                    <span class="bar bar-3"></span>
                    <span class="bar bar-4"></span>
                    <span class="bar bar-5"></span>
                  </div>
                </div>
              </div>
            </div>
          </main>

          <!-- Bottom Floating Dock -->
          <footer class="bottom-dock">
            <div class="font-controls">
              <button class="btn-dock" onclick="adjustFontSize(-2)" title="Smaller font">A-</button>
              <button class="btn-dock" onclick="adjustFontSize(2)" title="Larger font">A+</button>
            </div>
            <button class="btn-copy-transcript" onclick="copySubtitleText()">
              <span>📋</span>
              <span id="btnCopyText">Copy Transcript</span>
            </button>
            <button class="btn-dock" onclick="toggleFullscreen()" title="Toggle Fullscreen">
              <span>⤢</span>
            </button>
          </footer>

          <canvas id="pipCanvas" width="640" height="220"></canvas>
          <video id="pipVideo" playsinline webkit-playsinline muted autoplay></video>

          <script>
            // Supported Languages List from Mac Engine
            const allLanguages = \(languagesJson);

            // Multilingual Localizations for Mobile Web Captioner
            const I18N = {
              en: {
                appTitle: "Live Subtitles",
                live: "LIVE STREAM CONNECTED",
                translatingTo: "Translating to:",
                copyTranscript: "Copy Transcript",
                listening: "Listening for live speech in call...",
                speakerTag: "SPEAKER",
                copied: "✓ Subtitle copied",
                pipActive: "✓ Floating Subtitles Active",
                pipClosed: "Floating Subtitles Closed",
                pipFallback: "Tip: Use Split Screen or Keep Tab Open",
                synced: "● Synced with Mac"
              },
              es: {
                appTitle: "Subtítulos en Vivo",
                live: "TRANSMISIÓN EN VIVO CONECTADA",
                translatingTo: "Traduciendo a:",
                copyTranscript: "Copiar Transcripción",
                listening: "Escuchando conversación en vivo...",
                speakerTag: "HABLANTE",
                copied: "✓ Subtítulo copiado",
                pipActive: "✓ Subtítulos Flotantes Activos",
                pipClosed: "Subtítulos Flotantes Cerrados",
                pipFallback: "Consejo: Usa pantalla dividida o mantén la pestaña abierta",
                synced: "● Sincronizado con Mac"
              },
              fr: {
                appTitle: "Sous-titres en Direct",
                live: "FLUX EN DIRECT CONNECTÉ",
                translatingTo: "Traduction vers :",
                copyTranscript: "Copier la Transcription",
                listening: "En attente des paroles en direct...",
                speakerTag: "INTERLOCUTEUR",
                copied: "✓ Sous-titre copié",
                pipActive: "✓ Fenêtre Flottante Active",
                pipClosed: "Fenêtre Flottante Fermée",
                pipFallback: "Astuce : Utilisez l'écran partagé ou gardez l'onglet ouvert",
                synced: "● Synchronisé avec Mac"
              },
              de: {
                appTitle: "Live-Untertitel",
                live: "LIVE-STREAM VERBUNDEN",
                translatingTo: "Übersetzen auf:",
                copyTranscript: "Transkript Kopieren",
                listening: "Warte auf Sprache im Anruf...",
                speakerTag: "SPRECHER",
                copied: "✓ Untertitel kopiert",
                pipActive: "✓ Schwebende Untertitel Aktiv",
                pipClosed: "Schwebende Untertitel Beendet",
                pipFallback: "Tipp: Split-Screen verwenden oder Tab geöffnet lassen",
                synced: "● Mit Mac synchronisiert"
              },
              it: {
                appTitle: "Sottotitoli dal Vivo",
                live: "STREAMING DAL VIVO COLLEGATO",
                translatingTo: "Traduci in:",
                copyTranscript: "Copia Trascrizione",
                listening: "In ascolto della conversazione...",
                speakerTag: "INTERLOCUTORE",
                copied: "✓ Sottotitolo copiato",
                pipActive: "✓ Sottotitoli Fluttuanti Attivi",
                pipClosed: "Sottotitoli Fluttuanti Chiusi",
                pipFallback: "Suggerimento: Usa lo schermo diviso o mantieni aperta la scheda",
                synced: "● Sincronizzato con Mac"
              },
              pt: {
                appTitle: "Legendas ao Vivo",
                live: "TRANSMISSÃO AO VIVO CONECTADA",
                translatingTo: "Traduzindo para:",
                copyTranscript: "Copiar Transcrição",
                listening: "Ouvindo fala ao vivo na chamada...",
                speakerTag: "FALANTE",
                copied: "✓ Legenda copiada",
                pipActive: "✓ Legendas Flutuantes Ativas",
                pipClosed: "Legendas Flutuantes Fechadas",
                pipFallback: "Dica: Use tela dividida ou mantenha a guia aberta",
                synced: "● Sincronizado com Mac"
              },
              ar: {
                appTitle: "ترجمة مباشرة",
                live: "البث المباشر متصل",
                translatingTo: "الترجمة إلى:",
                copyTranscript: "نسخ النص",
                listening: "في انتظار الحديث المباشر في المكالمة...",
                speakerTag: "المتحدث",
                copied: "✓ تم نسخ الترجمة",
                pipActive: "✓ الترجمة العائمة نشطة",
                pipClosed: "تم إغلاق الترجمة العائمة",
                pipFallback: "تلميح: استخدم تقسيم الشاشة أو أبقِ علامة التبويب مفتوحة",
                synced: "● متزامن مع Mac"
              },
              zh: {
                appTitle: "实时通话字幕",
                live: "实时通话已连接",
                translatingTo: "翻译目标语言：",
                copyTranscript: "复制全部字幕",
                listening: "正在监听通话中的实时语音...",
                speakerTag: "说话者",
                copied: "✓ 字幕已复制",
                pipActive: "✓ 悬浮字幕已开启",
                pipClosed: "悬浮字幕已关闭",
                pipFallback: "提示：可使用分屏模式或保持此标签页打开",
                synced: "● 已与 Mac 同步"
              },
              ja: {
                appTitle: "通話リアルタイム字幕",
                live: "ライブ接続中",
                translatingTo: "翻訳先の言語:",
                copyTranscript: "文字起こしをコピー",
                listening: "通話中の音声をリアルタイム認識中...",
                speakerTag: "発話者",
                copied: "✓ 字幕をコピーしました",
                pipActive: "✓ フローティング字幕を起動しました",
                pipClosed: "フローティング字幕を閉じました",
                pipFallback: "ヒント: スプリットビューを使うかタブを開いたままにしてください",
                synced: "● Macと同期中"
              },
              ru: {
                appTitle: "Живые субтитры",
                live: "ПРЯМАЯ ТРАНСЛЯЦИЯ ПОДКЛЮЧЕНА",
                translatingTo: "Перевод на:",
                copyTranscript: "Копировать Транскрипт",
                listening: "Ожидание речи в звонке...",
                speakerTag: "СОБЕСЕДНИК",
                copied: "✓ Субтитры скопированы",
                pipActive: "✓ Плавающие субтитры включены",
                pipClosed: "Плавающие субтитры закрыты",
                pipFallback: "Совет: Используйте разделение экрана или не закрывайте вкладку",
                synced: "● Синхронизировано с Mac"
              },
              hi: {
                appTitle: "लाइव उपशीर्षक",
                live: "लाइव स्ट्रीम कनेक्टेड",
                translatingTo: "अनुवाद भाषा:",
                copyTranscript: "ट्रांसक्रिप्ट कॉपी करें",
                listening: "कॉल में बातचीत की प्रतीक्षा की जा रही है...",
                speakerTag: "वक्ता",
                copied: "✓ उपशीर्षक कॉपी हुआ",
                pipActive: "✓ फ्लोटिंग उपशीर्षक सक्रिय",
                pipClosed: "फ्लोटिंग उपशीर्षक बंद",
                pipFallback: "सुझाव: स्प्लिट स्क्रीन का उपयोग करें या टैब खुला रखें",
                synced: "● Mac के साथ समन्वयित"
              },
              ko: {
                appTitle: "실시간 통화 자막",
                live: "실시간 스트림 연결됨",
                translatingTo: "번역 대상 언어:",
                copyTranscript: "자막 복사",
                listening: "통화 중 음성을 듣는 중입니다...",
                speakerTag: "발화者",
                copied: "✓ 자막 복사됨",
                pipActive: "✓ 플로팅 자막 활성화됨",
                pipClosed: "플로팅 자막 닫힘",
                pipFallback: "팁: 화면 분할을 사용하거나 탭을 열어두세요",
                synced: "● Mac과 동기화됨"
              },
              nl: {
                appTitle: "Live Ondertiteling",
                live: "LIVE STREAM VERBONDEN",
                translatingTo: "Vertalen naar:",
                copyTranscript: "Kopieer Transcript",
                listening: "Luisteren naar spraak in gesprek...",
                speakerTag: "SPREKER",
                copied: "✓ Ondertitel gekopieerd",
                pipActive: "✓ Zwevende Ondertiteling Actief",
                pipClosed: "Zwevende Ondertiteling Gesloten",
                pipFallback: "Tip: Gebruik gesplitst scherm of houd tabblad open",
                synced: "● Gesynchroniseerd met Mac"
              },
              tr: {
                appTitle: "Canlı Altyazı",
                live: "CANLI YAYIN BAĞLANDI",
                translatingTo: "Çevrilecek Dil:",
                copyTranscript: "Metni Kopyala",
                listening: "Görüşmedeki konuşma dinleniyor...",
                speakerTag: "KONUŞMACI",
                copied: "✓ Altyazı kopyalandı",
                pipActive: "✓ Kayan Altyazı Aktif",
                pipClosed: "Kayan Altyazı Kapatıldı",
                pipFallback: "İpucu: Bölünmüş ekran kullanın veya sekmeyi açık tutun",
                synced: "● Mac ile Senkronize"
              },
              pl: {
                appTitle: "Napisy na Żywo",
                live: "STRUMIEŃ NA ŻYWO POŁĄCZONY",
                translatingTo: "Tłumacz na:",
                copyTranscript: "Kopiuj Transkrypcję",
                listening: "Oczekiwanie na mowę w rozmowie...",
                speakerTag: "ROZMÓWCA",
                copied: "✓ Skopiowano napisy",
                pipActive: "✓ Pływające Napisy Aktywne",
                pipClosed: "Pływające Napisy Zamknięte",
                pipFallback: "Wskazówka: Użyj podzielonego ekranu lub zachowaj otwartą kartę",
                synced: "● Zsynchronizowano z Mac"
              },
              uk: {
                appTitle: "Живі Субтитри",
                live: "ПРЯМИЙ ЕФІР ПІДКЛЮЧЕНО",
                translatingTo: "Переклад на:",
                copyTranscript: "Копіювати Текст",
                listening: "Очікування голосу у дзвінку...",
                speakerTag: "СПІВРОЗМОВНИК",
                copied: "✓ Субтитри скопійовано",
                pipActive: "✓ Плаваючі Субтитри Увімкнено",
                pipClosed: "Плаваючі Субтитри Закрито",
                pipFallback: "Порада: Використовуйте розділений екран або тримайте вкладку відкритою",
                synced: "● Синхронізовано з Mac"
              },
              vi: {
                appTitle: "Phụ Đề Trực Tiếp",
                live: "KẾT NỐI TRỰC TIẾP THÀNH CÔNG",
                translatingTo: "Dịch sang:",
                copyTranscript: "Sao Chép Phụ Đề",
                listening: "Đang lắng nghe trong cuộc gọi...",
                speakerTag: "NGƯỜI NÓI",
                copied: "✓ Đã sao chép phụ đề",
                pipActive: "✓ Phụ Đề Nổi Đang Bật",
                pipClosed: "Đã Đóng Phụ Đề Nổi",
                pipFallback: "Mẹo: Dùng chia đôi màn hình hoặc giữ tab mở",
                synced: "● Đã đồng bộ với Mac"
              },
              th: {
                appTitle: "คำบรรยายสด",
                live: "เชื่อมต่อสตรีมสดแล้ว",
                translatingTo: "แปลเป็นภาษา:",
                copyTranscript: "คัดลอกคำบรรยาย",
                listening: "กำลังรอรับเสียงสนทนา...",
                speakerTag: "ผู้พูด",
                copied: "✓ คัดลอกคำบรรยายแล้ว",
                pipActive: "✓ คำบรรยายลอยทำงานแล้ว",
                pipClosed: "ปิดคำบรรยายลอยแล้ว",
                pipFallback: "คำแนะนำ: ใช้โหมดแบ่งหน้าจอหรือเปิดแท็บทิ้งไว้",
                synced: "● ซิงค์กับ Mac แล้ว"
              },
              id: {
                appTitle: "Subtitel Langsung",
                live: "STREAM LANGSUNG TERHUBUNG",
                translatingTo: "Terjemahkan ke:",
                copyTranscript: "Salin Transkrip",
                listening: "Mendengarkan percakapan panggilan...",
                speakerTag: "PEMBICARA",
                copied: "✓ Subtitel disalin",
                pipActive: "✓ Subtitel Melayang Aktif",
                pipClosed: "Subtitel Melayang Ditutup",
                pipFallback: "Tips: Gunakan layar terbelah atau biarkan tab tetap terbuka",
                synced: "● Disinkronkan dengan Mac"
              },
              sv: {
                appTitle: "Live-Undertexter",
                live: "LIVE-STRÖM ANSLUTEN",
                translatingTo: "Översätt till:",
                copyTranscript: "Kopiera Transkript",
                listening: "Lyssnar på samtalet i realtid...",
                speakerTag: "TALARE",
                copied: "✓ Undertext kopierad",
                pipActive: "✓ Flytande Undertexter Aktiverade",
                pipClosed: "Flytande Undertexter Stängda",
                pipFallback: "Tips: Använd delad skärm eller håll fliken öppen",
                synced: "● Synkroniserad med Mac"
              }
            };

            let currentFontSize = 28;
            
            // Dynamic Active Language Codes & Names
            let hostLangCode = "\(hostLangCode)";
            let hostLangName = "\(hostLangName)";
            let callerLangCode = "\(callerLangCode)";
            let callerLangName = "\(callerLangName)";

            // Restore persistent user font size
            try {
              const savedFont = localStorage.getItem('wa_caption_font');
              if (savedFont) currentFontSize = parseInt(savedFont, 10);
            } catch(e) {}
            
            let hostOriginal = '';
            let hostTranslated = '';
            let callerOriginal = '';
            let callerTranslated = '';
            let activeSpeaker = '';
            let activeText = '';
            let orbPulseTimer = null;

            function getTranslationStrings() {
              return I18N[callerLangCode] || I18N['en'];
            }

            function populateLanguageDropdown() {
              const callerSelect = document.getElementById('callerLangSelect');
              if (!callerSelect) return;
              callerSelect.innerHTML = '';

              allLanguages.forEach(lang => {
                const opt = document.createElement('option');
                opt.value = lang.code;
                opt.textContent = lang.displayName || (lang.flag + ' ' + lang.name);
                if (lang.code === callerLangCode) opt.selected = true;
                callerSelect.appendChild(opt);
              });

              updateUIForLanguages();
            }

            function updateUIForLanguages() {
              const matchedCaller = allLanguages.find(l => l.code === callerLangCode);
              const matchedHost = allLanguages.find(l => l.code === hostLangCode);
              if (matchedCaller) callerLangName = matchedCaller.name;
              if (matchedHost) hostLangName = matchedHost.name;

              const t = getTranslationStrings();

              // Handle RTL layout for Arabic
              document.documentElement.dir = (callerLangCode === 'ar') ? 'rtl' : 'ltr';

              // Localize labels
              const statusText = document.getElementById('statusText');
              if (statusText) statusText.textContent = t.live;

              const transLabel = document.getElementById('translatingLabel');
              if (transLabel) transLabel.textContent = t.translatingTo;

              const btnCopy = document.getElementById('btnCopyText');
              if (btnCopy) btnCopy.textContent = t.copyTranscript;

              const langInd = document.getElementById('langIndicator');
              if (langInd) {
                langInd.textContent = hostLangCode.toUpperCase() + ' ➔ ' + callerLangCode.toUpperCase();
              }

              const transBox = document.getElementById('translatedText');
              if (transBox && !transBox.dataset.hasSpeech) {
                transBox.textContent = t.listening;
              }

              document.title = t.appTitle + " • " + callerLangName;
              drawPiPCanvas();
            }

            function onLanguageSelectionChanged() {
              const callerSelect = document.getElementById('callerLangSelect');
              if (callerSelect) callerLangCode = callerSelect.value;

              updateUIForLanguages();
              notifyServerLanguageChange();
              renderSubtitles();
            }

            function notifyServerLanguageChange() {
              fetch('/set-languages?host=' + encodeURIComponent(hostLangCode) + '&caller=' + encodeURIComponent(callerLangCode))
                .then(r => r.json())
                .catch(() => {});
            }

            function triggerVoicePulse() {
              const orb = document.getElementById('voiceOrb');
              if (orb) {
                orb.classList.add('speaking');
                if (orbPulseTimer) clearTimeout(orbPulseTimer);
                orbPulseTimer = setTimeout(() => {
                  orb.classList.remove('speaking');
                }, 2800);
              }
            }

            function showToast(msg) {
              let t = document.getElementById('toastMsg');
              if (!t) {
                t = document.createElement('div');
                t.id = 'toastMsg';
                t.className = 'toast';
                document.body.appendChild(t);
              }
              t.textContent = msg;
              t.classList.add('show');
              setTimeout(() => t.classList.remove('show'), 1600);
            }

            function copySubtitleText() {
              if (window.navigator && window.navigator.vibrate) window.navigator.vibrate(15);
              const text = document.getElementById('translatedText')?.textContent || '';
              const t = getTranslationStrings();
              if (text && navigator.clipboard) {
                navigator.clipboard.writeText(text).then(() => {
                  showToast(t.copied);
                }).catch(() => {
                  showToast(t.copied);
                });
              } else if (text) {
                showToast(t.copied);
              }
            }

            function adjustFontSize(delta) {
              if (window.navigator && window.navigator.vibrate) window.navigator.vibrate(10);
              currentFontSize = Math.max(18, Math.min(44, currentFontSize + delta));
              const trans = document.getElementById('translatedText');
              if (trans) trans.style.fontSize = currentFontSize + 'px';
              try { localStorage.setItem('wa_caption_font', currentFontSize); } catch(e) {}
              drawPiPCanvas();
            }

            function toggleFullscreen() {
              if (!document.fullscreenElement) {
                document.documentElement.requestFullscreen().catch(() => {});
              } else {
                document.exitFullscreen().catch(() => {});
              }
            }

            window.addEventListener('DOMContentLoaded', () => {
              populateLanguageDropdown();
              const trans = document.getElementById('translatedText');
              if (trans) trans.style.fontSize = currentFontSize + 'px';
            });

            // Server-Sent Events (SSE) Stream
            const evtSource = new EventSource('/events');

            evtSource.onmessage = function(e) {
              try {
                const data = JSON.parse(e.data);

                if (data.type === 'languages') {
                  if (data.hostLangCode) hostLangCode = data.hostLangCode;
                  if (data.callerLangCode) callerLangCode = data.callerLangCode;
                  const callerSelect = document.getElementById('callerLangSelect');
                  if (callerSelect) callerSelect.value = callerLangCode;
                  updateUIForLanguages();
                  renderSubtitles();
                  return;
                }
                
                if (data.type === 'init') {
                  if (data.hostLangCode) hostLangCode = data.hostLangCode;
                  if (data.callerLangCode) callerLangCode = data.callerLangCode;
                  const callerSelect = document.getElementById('callerLangSelect');
                  if (callerSelect) callerSelect.value = callerLangCode;
                  updateUIForLanguages();
                }

                const speaker = data.speaker || '';
                const orig = data.original || '';
                const trans = data.translated || '';
                const callerDisp = data.displayForCaller || trans;

                // Identify speaker
                if (speaker.toLowerCase().includes('caller') || speaker.toLowerCase().includes('tú')) {
                  callerOriginal = orig;
                  callerTranslated = trans;
                } else {
                  hostOriginal = orig;
                  hostTranslated = trans;
                }

                triggerVoicePulse();
                renderSubtitles(speaker, orig, trans, callerDisp);
              } catch (err) {
                console.error('Error handling SSE event:', err);
              }
            };

            function renderSubtitles(speaker, orig, trans, callerDisp) {
              const spkLabel = document.getElementById('speakerLabel');
              const origLabel = document.getElementById('originalText');
              const transLabel = document.getElementById('translatedText');
              const t = getTranslationStrings();

              if (hostTranslated || hostOriginal) {
                spkLabel.textContent = t.speakerTag + ' (' + hostLangName + ')';
                origLabel.textContent = hostOriginal;
                transLabel.textContent = hostTranslated || hostOriginal;
                transLabel.dataset.hasSpeech = 'true';
                activeSpeaker = hostLangName + ' ➔ ' + callerLangName;
                activeText = hostTranslated || hostOriginal;
              } else if (callerOriginal) {
                spkLabel.textContent = callerLangName.toUpperCase();
                origLabel.textContent = '';
                transLabel.textContent = callerOriginal;
                transLabel.dataset.hasSpeech = 'true';
                activeSpeaker = callerLangName;
                activeText = callerOriginal;
              }

              drawPiPCanvas();
            }

            evtSource.onerror = function() {
              const dot = document.getElementById('statusDot');
              const badge = document.getElementById('statusText');
              if (dot) {
                dot.style.background = '#ff9800';
                dot.style.boxShadow = 'none';
              }
              if (badge) {
                badge.textContent = 'CONNECTING...';
                badge.style.color = '#ff9800';
              }
            };

            evtSource.onopen = function() {
              const dot = document.getElementById('statusDot');
              const badge = document.getElementById('statusText');
              const t = getTranslationStrings();
              if (dot) {
                dot.style.background = '#10b981';
                dot.style.boxShadow = '0 0 12px #10b981';
              }
              if (badge) {
                badge.textContent = t.live;
                badge.style.color = '#10b981';
              }
            };

            // Picture-in-Picture (PiP) Renderer for iOS & Android
            const canvas = document.getElementById('pipCanvas');
            const ctx = canvas.getContext('2d');
            const video = document.getElementById('pipVideo');
            let pipStream = null;
            let audioContext = null;

            function drawPiPCanvas() {
              const t = getTranslationStrings();

              ctx.fillStyle = '#06090e';
              ctx.fillRect(0, 0, canvas.width, canvas.height);

              ctx.strokeStyle = '#10b981';
              ctx.lineWidth = 3;
              ctx.strokeRect(3, 3, canvas.width - 6, canvas.height - 6);

              ctx.fillStyle = 'rgba(16, 185, 129, 0.15)';
              ctx.fillRect(4, 4, canvas.width - 8, 36);

              ctx.fillStyle = '#10b981';
              ctx.font = 'bold 15px sans-serif';
              ctx.fillText('● ' + (activeSpeaker || t.appTitle), 16, 28);

              ctx.fillStyle = '#ffffff';
              ctx.font = 'bold 24px sans-serif';
              wrapText(ctx, activeText || t.listening, 16, 76, canvas.width - 32, 32);
            }

            function wrapText(context, text, x, y, maxWidth, lineHeight) {
              const words = text.split(' ');
              let line = '';
              for (let n = 0; n < words.length; n++) {
                const testLine = line + words[n] + ' ';
                const metrics = context.measureText(testLine);
                if (metrics.width > maxWidth && n > 0) {
                  context.fillText(line, x, y);
                  line = words[n] + ' ';
                  y += lineHeight;
                  if (y > canvas.height - 18) break;
                } else {
                  line = testLine;
                }
              }
              context.fillText(line, x, y);
            }

            function initPiPStream() {
              if (pipStream) return;
              try {
                drawPiPCanvas();
                pipStream = canvas.captureStream(15);

                try {
                  const AudioCtx = window.AudioContext || window.webkitAudioContext;
                  if (AudioCtx) {
                    audioContext = new AudioCtx();
                    const osc = audioContext.createOscillator();
                    const dst = audioContext.createMediaStreamDestination();
                    osc.connect(dst);
                    osc.start();
                    const track = dst.stream.getAudioTracks()[0];
                    if (track) {
                      track.enabled = false;
                      pipStream.addTrack(track);
                    }
                  }
                } catch (e) {}

                video.muted = true;
                video.defaultMuted = true;
                video.playsInline = true;
                video.volume = 0;
                video.srcObject = pipStream;
                video.play().catch(() => {});
              } catch (e) {
                console.warn('PiP init error:', e);
              }
            }

            function togglePiP() {
              drawPiPCanvas();
              initPiPStream();
              const t = getTranslationStrings();

              if (audioContext && audioContext.state === 'suspended') {
                audioContext.resume().catch(() => {});
              }

              // Toggle PiP off if already active
              if (document.pictureInPictureElement) {
                document.exitPictureInPicture().catch(() => {});
                showToast(t.pipClosed);
                return;
              }
              if (video.webkitPresentationMode === 'picture-in-picture') {
                try { video.webkitSetPresentationMode('inline'); } catch(e) {}
                showToast(t.pipClosed);
                return;
              }

              if (video.paused) {
                video.play().catch(() => {});
              }

              const executePiP = () => {
                if (video.requestPictureInPicture) {
                  video.requestPictureInPicture().then(() => {
                    showToast(t.pipActive);
                  }).catch(err => {
                    console.warn('PiP standard request fallback:', err);
                    if (video.webkitSetPresentationMode) {
                      try {
                        video.webkitSetPresentationMode('picture-in-picture');
                        showToast(t.pipActive);
                      } catch(e) {
                        showToast(t.pipFallback);
                      }
                    } else {
                      showToast(t.pipFallback);
                    }
                  });
                } else if (video.webkitSetPresentationMode) {
                  try {
                    video.webkitSetPresentationMode('picture-in-picture');
                    showToast(t.pipActive);
                  } catch(e) {
                    showToast(t.pipFallback);
                  }
                } else {
                  showToast(t.pipFallback);
                }
              };

              if (video.readyState >= 1) {
                executePiP();
              } else {
                const onReady = () => {
                  video.removeEventListener('loadedmetadata', onReady);
                  video.removeEventListener('canplay', onReady);
                  video.removeEventListener('playing', onReady);
                  executePiP();
                };
                video.addEventListener('loadedmetadata', onReady);
                video.addEventListener('canplay', onReady);
                video.addEventListener('playing', onReady);
                video.play().then(() => {
                  if (video.readyState >= 1) {
                    onReady();
                  }
                }).catch(() => {
                  executePiP();
                });
              }
            }

            video.addEventListener('enterpictureinpicture', () => {
              showToast(getTranslationStrings().pipActive);
            });
            video.addEventListener('leavepictureinpicture', () => {
              showToast(getTranslationStrings().pipClosed);
            });
            video.addEventListener('webkitpresentationmodechanged', () => {
              const t = getTranslationStrings();
              if (video.webkitPresentationMode === 'picture-in-picture') {
                showToast(t.pipActive);
              } else if (video.webkitPresentationMode === 'inline') {
                showToast(t.pipClosed);
              }
            });

            // Initial render and pre-warm PiP stream so first click activates instantly
            drawPiPCanvas();
            initPiPStream();
            setInterval(drawPiPCanvas, 1000);

            // Pre-warm on earliest touch / click anywhere on the page
            window.addEventListener('touchstart', initPiPStream, { once: true, passive: true });
            window.addEventListener('mousedown', initPiPStream, { once: true, passive: true });
          </script>
        </body>
        </html>
        """
    }
}
