// The PDF renderer for the browser reader: Mozilla PDF.js, self-hosted.
// The reader configures it without scripting, forms, XFA or an annotation
// layer, and loads its worker, fonts, CMaps and WebAssembly from Shelfarr's
// own digested assets (see build_pdf.js and consumer_page_reader.js).
export { getDocument, GlobalWorkerOptions, TextLayer, AnnotationMode, PasswordException, InvalidPDFException, version } from "pdfjs-dist"
