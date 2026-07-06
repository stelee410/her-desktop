chrome.storage.local.get(["port", "token"], (cfg) => {
  document.getElementById("port").value = cfg.port || 8799;
  document.getElementById("token").value = cfg.token || "";
});

document.getElementById("save").addEventListener("click", () => {
  const port = parseInt(document.getElementById("port").value, 10) || 8799;
  const token = document.getElementById("token").value.trim();
  chrome.storage.local.set({ port, token }, () => {
    document.getElementById("status").textContent = "已保存，Her 现在可以驱动这个 Chrome 了。";
  });
});
