const DATABASE = "shelfarr-go-preview-offline"
const DEFAULT_MOUNT = "/preview"
const ACCOUNT_KEY = "current"

export function previewDatabaseName(base) {
  const mount = `${base}/preview`
  return mount === DEFAULT_MOUNT ? DATABASE : `${DATABASE}|${mount}`
}

function completed(request) {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result)
    request.onerror = () => reject(request.error)
  })
}

function openExisting(factory, name) {
  return new Promise((resolve, reject) => {
    const request = factory.open(name)
    request.onupgradeneeded = () => request.transaction.abort()
    request.onsuccess = () => resolve(request.result)
    request.onerror = () => reject(request.error)
  })
}

export async function releasePreviewAccount(base, askedAt = Date.now(), factory = globalThis.indexedDB) {
  if (typeof factory?.databases !== "function") return false
  const name = previewDatabaseName(base)
  if (!(await factory.databases()).some(database => database.name === name)) return false
  const database = await openExisting(factory, name)
  try {
    const transaction = database.transaction("account", "readwrite")
    const accounts = transaction.objectStore("account")
    const stored = await completed(accounts.get(ACCOUNT_KEY))
    const record = stored?.record && stored.record.confirmedAt <= askedAt ? null : stored?.record ?? null
    accounts.put({ id: ACCOUNT_KEY, record, clearedAt: Math.max(stored?.clearedAt ?? 0, askedAt) })
    await new Promise((resolve, reject) => {
      transaction.oncomplete = resolve
      transaction.onerror = () => reject(transaction.error)
      transaction.onabort = () => reject(transaction.error)
    })
    return record === null
  } finally {
    database.close()
  }
}
