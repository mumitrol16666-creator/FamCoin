{{flutter_js}}
{{flutter_build_config}}

(function () {
  // Движок уже входит в сборку. Запуск не должен зависеть от доступности
  // внешнего CDN, особенно при открытии сайта через мобильную сеть.
  var config = { canvasKitBaseUrl: 'canvaskit/' };
  var ios = /iPad|iPhone|iPod/.test(navigator.userAgent) ||
    (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
  if (ios) config.renderer = 'canvaskit';

  function failed() { window.famcoinStartup.fail(); }
  _flutter.loader.load({
    config: config,
    onEntrypointLoaded: async function (engineInitializer) {
      try {
        var runner = await engineInitializer.initializeEngine(config);
        await runner.runApp();
      } catch (error) {
        failed();
        console.error('FamCoin initialization failed', error);
      }
    }
  }).catch(function (error) {
    failed();
    console.error('FamCoin loader failed', error);
  });
})();
