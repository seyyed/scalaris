/**
 *  Copyright 2007-2011 Zuse Institute Berlin
 *
 *   Licensed under the Apache License, Version 2.0 (the "License");
 *   you may not use this file except in compliance with the License.
 *   You may obtain a copy of the License at
 *
 *       http://www.apache.org/licenses/LICENSE-2.0
 *
 *   Unless required by applicable law or agreed to in writing, software
 *   distributed under the License is distributed on an "AS IS" BASIS,
 *   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *   See the License for the specific language governing permissions and
 *   limitations under the License.
 */
package de.zib.scalaris.examples.wikipedia.bliki;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.FilenameFilter;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.PrintStream;
import java.io.PrintWriter;
import java.io.UnsupportedEncodingException;
import java.math.BigInteger;
import java.net.URLEncoder;
import java.util.Arrays;
import java.util.Calendar;
import java.util.Collections;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.LinkedList;
import java.util.List;
import java.util.Map;
import java.util.Map.Entry;
import java.util.Properties;
import java.util.Random;
import java.util.TimeZone;
import java.util.regex.Pattern;

import javax.servlet.RequestDispatcher;
import javax.servlet.Servlet;
import javax.servlet.ServletConfig;
import javax.servlet.ServletException;
import javax.servlet.http.HttpServlet;
import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;

import org.apache.commons.lang.StringEscapeUtils;
import org.xml.sax.InputSource;
import org.xml.sax.XMLReader;
import org.xml.sax.helpers.XMLReaderFactory;

import de.zib.scalaris.Connection;
import de.zib.scalaris.ConnectionFactory;
import de.zib.scalaris.TransactionSingleOp;
import de.zib.scalaris.examples.wikipedia.NamespaceUtils;
import de.zib.scalaris.examples.wikipedia.PageHistoryResult;
import de.zib.scalaris.examples.wikipedia.PageListResult;
import de.zib.scalaris.examples.wikipedia.RandomTitleResult;
import de.zib.scalaris.examples.wikipedia.RevisionResult;
import de.zib.scalaris.examples.wikipedia.SavePageResult;
import de.zib.scalaris.examples.wikipedia.ScalarisDataHandler;
import de.zib.scalaris.examples.wikipedia.WikiServletContext;
import de.zib.scalaris.examples.wikipedia.bliki.WikiPageListBean.FormType;
import de.zib.scalaris.examples.wikipedia.data.Contributor;
import de.zib.scalaris.examples.wikipedia.data.Revision;
import de.zib.scalaris.examples.wikipedia.data.SiteInfo;
import de.zib.scalaris.examples.wikipedia.data.xml.SAXParsingInterruptedException;
import de.zib.scalaris.examples.wikipedia.data.xml.WikiDumpHandler;
import de.zib.scalaris.examples.wikipedia.data.xml.WikiDumpToScalarisHandler;
import de.zib.scalaris.examples.wikipedia.plugin.WikiEventHandler;
import de.zib.scalaris.examples.wikipedia.plugin.PluginClassLoader;
import de.zib.scalaris.examples.wikipedia.plugin.WikiPlugin;

/**
 * Servlet for handling wiki page display and editing.
 * 
 * @author Nico Kruber, kruber@zib.de
 */
public class WikiServlet extends HttpServlet implements Servlet, WikiServletContext {
    private static final String MAIN_PAGE = "Main Page";
    private static final int IMPORT_REDIRECT_EVERY = 5; // seconds

    private static final long serialVersionUID = 1L;
    
    /**
     * Version of the "Wikipedia on Scalaris" example implementation.
     */
    public static final String version = "0.3.0";

    private Connection connection = null; 
    private SiteInfo siteinfo = null;
    private MyNamespace namespace = null;
    private Random random = null;
    
    private boolean initialized = false;

    /**
     * Name under which the servlet is available.
     */
    public static final String wikiBaseURL = "wiki";
    /**
     * URL for page links
     */
    public static final String linkBaseURL = WikiServlet.wikiBaseURL + "?title=${title}";
    /**
     * URL for image links
     */
    public static final String imageBaseURL = "images/image.png";
    
    private static final Pattern MATCH_WIKI_IMPORT_FILE = Pattern.compile(".*\\.xml(\\.gz|\\.bz2)?$");
    
    private ConnectionFactory cFactory;
    
    private String currentImport = "";

    private WikiDumpHandler importHandler = null;
    
    private List<WikiEventHandler> eventHandlers = new LinkedList<WikiEventHandler>();

    /**
     * Creates the servlet. 
     */
    public WikiServlet() {
        super();
    }

    /**
     * Servlet initialisation: creates the connection to the erlang node.
     * 
     * @see #setupChordSharpConnection(HttpServletRequest)
     */
    @Override
    public void init(ServletConfig config) throws ServletException {
        super.init(config);
        Properties properties = new Properties();
        try {
            InputStream fis = config.getServletContext().getResourceAsStream("/WEB-INF/scalaris.properties");
            if (fis != null) {
                properties.load(fis);
                properties.setProperty("PropertyLoader.loadedfile", "/WEB-INF/scalaris.properties");
                fis.close();
            } else {
                properties = null;
            }
        } catch (IOException e) {
//            e.printStackTrace();
            properties = null;
        }
        
        if (properties != null) {
            cFactory = new ConnectionFactory(properties);
            cFactory.setClientNameAppendUUID(true);
        } else {
            cFactory = new ConnectionFactory();
            cFactory.setClientName("wiki_renderer");
            cFactory.setClientNameAppendUUID(true);
        }
        
        setupChordSharpConnection(null);
        random = new Random();
    }

        /**
     * Sets up the connection to the Scalaris erlang node once on the server.
     * 
     * @param config
     *            the servlet's configuration
     */
    @SuppressWarnings("unchecked")
    private boolean setupChordSharpConnection(HttpServletRequest request) {
        TransactionSingleOp scalaris_single;
        try {
            connection = cFactory.createConnection();
            scalaris_single = new TransactionSingleOp(connection);
        } catch (Exception e) {
            if (request != null) {
                addToParam_notice(request, "error: <pre>" + e.getMessage() + "</pre>");
            } else {
                System.out.println(e);
                e.printStackTrace();
            }
            return false;
        }
        try {
            siteinfo = scalaris_single.read("siteinfo").jsonValue(SiteInfo.class);
            // TODO: fix siteinfo's base url
            namespace = new MyNamespace(siteinfo);
            initialized = true;
        } catch (Exception e) {
            // no warning here - this probably is an empty wiki
            return false;
        }
        final String pluginDir = getServletContext().getRealPath("/WEB-INF/plugins");
        try {
            PluginClassLoader pcl = new PluginClassLoader(pluginDir, new Class[] {WikiPlugin.class});
            List<Class<?>> plugins = pcl.getClasses(WikiPlugin.class);
            if (plugins != null) {
                for (Class<?> clazz: plugins) {
                    WikiPlugin plugin;
                    try {
                        plugin = ((Class<WikiPlugin>) clazz).newInstance();
                        plugin.init(this);
                    } catch (Exception e) {
                        System.err.println("failed to load plugin " + clazz.getCanonicalName());
                        e.printStackTrace();
                        continue;
                    }
                }
            }
        } catch (IOException e) {
            System.err.println("failed to load plugins");
            e.printStackTrace();
        }
        return true;
    }

    @Override
    public void destroy() {
    }

    /*
     * (non-Javadoc)
     * 
     * @see javax.servlet.http.HttpServlet#doGet(HttpServletRequest request,
     *      HttpServletResponse response)
     */
    @Override
    protected void doGet(HttpServletRequest request,
            HttpServletResponse response) throws ServletException, IOException {
        if (!initialized && !setupChordSharpConnection(request) || !currentImport.isEmpty()) {
            showImportPage(request, response);
            return;
        }
        request.setCharacterEncoding("UTF-8");
        response.setCharacterEncoding("UTF-8");
        
        // show empty page for testing purposes if a parameter called "test" exists:
        if (request.getParameter("test") != null) {
            showEmptyPage(request, response);
            return;
        }
        
        // get parameters:
        String req_title = request.getParameter("title");
        if (req_title == null) {
            req_title = MAIN_PAGE;
        }

        
        String req_action = request.getParameter("action");

        if (req_title.equals("Special:Random")) {
            handleViewRandomPage(request, response);
        } else if (req_title.startsWith("Special:AllPages") || req_title.startsWith("Special:Allpages")) {
            String req_from = request.getParameter("from");
            if (req_from == null) {
                req_from = ""; // shows all pages
                int slashIndex = req_title.indexOf('/');
                if (slashIndex != (-1)) {
                    req_from = req_title.substring(slashIndex + 1);
                }
            }
            String req_to = request.getParameter("to");
            if (req_to == null) {
                req_to = ""; // shows all pages
            }
            // use default namespace (id 0) for invalid values
            int nsId = parseInt(request.getParameter("namespace"), 0);
            WikiPageListBean value = new WikiPageListBean();
            value.setPageHeading("All pages");
            value.setTitle("Special:AllPages&from=" + req_from + "&to=" + req_to);
            value.setFormTitle("All pages");
            value.setFormType(FormType.FromToForm);
            value.setFromPage(req_from);
            value.setToPage(req_to);
            PageListResult result;
            if (nsId == 0) {
                result = ScalarisDataHandler.getArticleList(connection);
            } else {
                result = ScalarisDataHandler.getPageList(connection);
                value.setNamespaceId(nsId);
            }
            handleViewSpecialPageList(request, response, result, value);
        } else if (req_title.startsWith("Special:PrefixIndex")) {
            String req_prefix = request.getParameter("prefix");
            if (req_prefix == null) {
                req_prefix = ""; // shows all pages
                int slashIndex = req_title.indexOf('/');
                if (slashIndex != (-1)) {
                    req_prefix = req_title.substring(slashIndex + 1);
                }
            }
            // use default namespace (id 0) for invalid values
            int nsId = parseInt(request.getParameter("namespace"), 0);
            WikiPageListBean value = new WikiPageListBean();
            value.setPageHeading("All pages");
            value.setTitle("Special:PrefixIndex&prefix=" + req_prefix);
            value.setFormTitle("All pages");
            value.setFormType(FormType.PagePrefixForm);
            value.setPrefix(req_prefix);
            PageListResult result;
            if (nsId == 0) {
                result = ScalarisDataHandler.getArticleList(connection);
            } else {
                result = ScalarisDataHandler.getPageList(connection);
                value.setNamespaceId(nsId);
            }
            handleViewSpecialPageList(request, response, result, value);
        } else if (req_title.startsWith("Special:WhatLinksHere")) {
            String req_target = request.getParameter("target");
            if (req_target == null) {
                req_target = ""; // will show an empty page list
                // maybe we got the name separated with a '/' in the title:
                int slashIndex = req_title.indexOf('/');
                if (slashIndex != (-1)) {
                    req_target = req_title.substring(slashIndex + 1);
                }
            }
            WikiPageListBean value = new WikiPageListBean();
            value.setPageHeading("Pages that link to \"" + req_target + "\"");
            value.setTitle("Special:WhatLinksHere&target=" + req_target);
            value.setFormTitle("What links here");
            value.setFormType(FormType.TargetPageForm);
            value.setTarget(req_target);
            PageListResult result = ScalarisDataHandler.getPagesLinkingTo(connection, req_target);
            handleViewSpecialPageList(request, response, result, value);
        } else if (req_title.equals("Special:SpecialPages")) {
            handleViewSpecialPages(request, response);
        } else if (req_title.equals("Special:Statistics")) {
            handleViewSpecialStatistics(request, response);
        } else if (req_title.equals("Special:Version")) {
            handleViewSpecialVersion(request, response);
        } else if (req_action == null || req_action.equals("view")) {
            handleViewPage(request, response, req_title);
        } else if (req_action.equals("history")) {
            handleViewPageHistory(request, response, req_title);
        } else if (req_action.equals("edit")) {
            handleEditPage(request, response, req_title);
        } else {
            // default: show page
            handleViewPage(request, response, req_title);
        }

        // if the request has not been forwarded, print a general error
        response.setContentType("text/html");
        PrintWriter out = response.getWriter();
        out.write("An unknown error occured, please contact your administrator. A server restart may be required.");
        out.close();
    }

    /*
     * (non-Javadoc)
     * 
     * @see javax.servlet.http.HttpServlet#doPost(HttpServletRequest request,
     *      HttpServletResponse response)
     */
    @Override
    protected void doPost(HttpServletRequest request,
            HttpServletResponse response) throws ServletException, IOException {
        if (!initialized && !setupChordSharpConnection(request) || !currentImport.isEmpty()) {
            showImportPage(request, response);
        }
        request.setCharacterEncoding("UTF-8");
        response.setCharacterEncoding("UTF-8");
        
        // for debugging, show all parameters:
//        Enumeration test = request.getParameterNames();
//        while (test.hasMoreElements()) {
//            String element = (String) test.nextElement();
//            System.out.println(element);
//            System.out.println(request.getParameter(element));
//        }
        handleEditPageSubmitted(request, response, request.getParameter("title"));
        
        // if the request has not been forwarded, print a general error
        response.setContentType("text/html");
        PrintWriter out = response.getWriter();
        out.write("An unknown error occured, please contact your administrator. A server restart may be required.");
        out.close();
    }

    /**
     * Gets a random page and forwards the user to the site with this page.
     * 
     * @param request
     *            the request of the current operation
     * @param response
     *            the response of the current operation
     * 
     * @throws IOException
     *            if the forward fails
     */
    private void handleViewRandomPage(HttpServletRequest request,
            HttpServletResponse response) throws IOException {
        RandomTitleResult result = ScalarisDataHandler.getRandomArticle(connection, random);
        if (result.success) {
            response.sendRedirect(response.encodeRedirectURL("?title=" + URLEncoder.encode(result.title, "UTF-8")));
        } else {
            response.sendRedirect(response.encodeRedirectURL("?title=Main Page&notice=error: can not view random page: <pre>" + result.message + "</pre>"));
        }
    }

    /**
     * Shows the contents of the page page with the given <tt>title</tt>.
     * 
     * @param request
     *            the request of the current operation
     * @param response
     *            the response of the current operation
     * @param title
     *            the title of the page to show
     * 
     * @throws IOException 
     * @throws ServletException 
     */
    private void handleViewPage(HttpServletRequest request,
            HttpServletResponse response, String title) throws ServletException, IOException {
        // get renderer
        int render = WikiServlet.getParam_renderer(request);
        // get revision id to load:
        int req_oldid = WikiServlet.getParam_oldid(request);

        RevisionResult result = ScalarisDataHandler.getRevision(connection, title, req_oldid);
        if (result.page_not_existing) {
            handleViewPageNotExisting(request, response, title);
            return;
        } else if (result.rev_not_existing) {
            result = ScalarisDataHandler.getRevision(connection, title);
            addToParam_notice(request, "revision " + req_oldid + " not found - loaded current revision instead");
        }
        
        if (result.success) {
            WikiPageBean value = renderRevision(title, result.revision, render, request);
            
            if (!result.page.checkEditAllowed("")) {
                value.setEditRestricted(true);
            }

            // forward the request and the bean to the jsp:
            request.setAttribute("pageBean", value);
            RequestDispatcher dispatcher = request
                    .getRequestDispatcher("page.jsp");
            dispatcher.forward(request, response);
        } else {
            addToParam_notice(request, "error: unknown error getting page " + title + ":" + req_oldid + ": <pre>" + result.message + "</pre>");
            showEmptyPage(request, response);
        }
    }
    
    /**
     * Extracts the full base URL from a requested URL.
     * 
     * @param requestUrl
     *            the URL from the request
     * 
     * @return the first part of the URL preceding '/' + {@link #wikiBaseURL}
     */
    private static String extractFullUrl(String requestUrl) {
        int colonIndex = requestUrl.indexOf('/' + wikiBaseURL);
        if (colonIndex != (-1)) {
            return requestUrl.substring(0, colonIndex + 1) + linkBaseURL;
        }
        return null;
        
    }
    
    /**
     * Creates a {@link WikiPageBean} object with the rendered content of a
     * given revision.
     * 
     * @param title
     *            the title of the article to render
     * @param revision
     *            the revision to render
     * @param renderer
     *            the renderer to use (0=plain text, 1=Bliki)
     * @param request
     *            the request object
     * 
     * @return a bean with the rendered content for the jsp
     */
    private WikiPageBean renderRevision(String title, Revision revision, int renderer, HttpServletRequest request) {
        String notice = WikiServlet.getParam_notice(request);
        // set the page's contents according to the renderer used
        // (categories are included in the content string, so they only
        // need special handling the wiki renderer is used)
        WikiPageBean value = new WikiPageBean();
        value.setNotice(notice);
        MyWikiModel wikiModel = getWikiModel();
        String fullUrl = extractFullUrl(request.getRequestURL().toString());
        if (fullUrl != null) {
            wikiModel.setLinkBaseFullURL(fullUrl);
        }
        wikiModel.setPageName(title);
        if (renderer > 0) {
            String mainText = wikiModel.render(revision.getText());
            if (wikiModel.isCategoryNamespace(MyWikiModel.getNamespace(title))) {
                PageListResult catPagesResult = ScalarisDataHandler.getPagesInCategory(connection, title);
                if (catPagesResult.success) {
                    LinkedList<String> subCategories = new LinkedList<String>();
                    LinkedList<String> categoryPages = new LinkedList<String>();
                    for (String page: catPagesResult.pages) {
                        String pageNamespace = MyWikiModel.getNamespace(page);
                        if (wikiModel.isCategoryNamespace(pageNamespace)) {
                            subCategories.add(MyWikiModel.getTitleName(page));
                        } else if (wikiModel.isTemplateNamespace(pageNamespace)) {
                            // all pages using a template are in the category, too
                            PageListResult tplResult = ScalarisDataHandler.getPagesInTemplate(connection, page);
                            if (tplResult.success) {
                                categoryPages.addAll(tplResult.pages);
                            }
                        } else {
                            categoryPages.add(page);
                        }
                    }
                    Collections.sort(subCategories);
                    Collections.sort(categoryPages);
                    value.setSubCategories(subCategories);
                    value.setCategoryPages(categoryPages);
                } else {
                    addToParam_notice(request, "error getting category pages: " + catPagesResult.message);
                }
            }
            if (wikiModel.getRedirectLink() != null) {
                String redirectedPageName = wikiModel.getRedirectLink();
                value.setRedirectedTo(redirectedPageName);
                // add the content from the page directed to:
                mainText = wikiModel.render(wikiModel.getRedirectContent(redirectedPageName));
            }
            value.setPage(mainText);
            value.setCategories(wikiModel.getCategories().keySet());
        } else if (renderer == 0) {
            value.setPage("<p>WikiText:<pre>"
                    + StringEscapeUtils.escapeHtml(revision.getText()) + "</pre></p>" +
                    "<p>Version:<pre>"
                    + StringEscapeUtils.escapeHtml(String.valueOf(revision.getId())) + "</pre></p>" +
                    "<p>Last change:<pre>"
                    + StringEscapeUtils.escapeHtml(revision.getTimestamp()) + "</pre></p>" +
                    "<p>Categories:<pre>"
                    + StringEscapeUtils.escapeHtml(revision.parseCategories(wikiModel).toString()) + "</pre></p>");
        }

        value.setTitle(title);
        value.setVersion(revision.getId());
        value.setWikiTitle(siteinfo.getSitename());
        value.setWikiNamespace(namespace);

        // extract the date:
        value.setDate(Revision.stringToCalendar(revision.getTimestamp()));
        return value;
    }
    
    /**
     * Shows the "Page not available" message the wiki returns in case a page
     * does not exist.
     * 
     * @param request
     *            the request of the current operation
     * @param response
     *            the response of the current operation
     * @param title
     *            the original title of the page that does not exist
     * 
     * @throws IOException 
     * @throws ServletException 
     */
    private void handleViewPageNotExisting(HttpServletRequest request,
            HttpServletResponse response, String title) throws ServletException, IOException {
        // get renderer
        int render = WikiServlet.getParam_renderer(request);
        String notExistingTitle = "MediaWiki:Noarticletext";

        RevisionResult result = ScalarisDataHandler.getRevision(connection, notExistingTitle);
        
        WikiPageBean value;
        if (result.success) {
            value = renderRevision(title, result.revision, render, request);
        } else {
//            addToParam_notice(request, "error: unknown error getting page " + notExistingTitle + ": <pre>" + result.message + "</pre>");
            value = new WikiPageBean();
            value.setPage("Page not available.");
            value.setTitle(title);
        }
        // re-set version (we are only showing this page due to a non-existing page)
        value.setVersion(-1);
        value.setNotAvailable(true);
        value.setNotice(WikiServlet.getParam_notice(request));
        value.setWikiTitle(siteinfo.getSitename());
        value.setWikiNamespace(namespace);

        // forward the request and the bean to the jsp:
        request.setAttribute("pageBean", value);
        RequestDispatcher dispatcher = request
                .getRequestDispatcher("page.jsp");
        dispatcher.forward(request, response);
    }

    /**
     * Shows the page containing the history information of an article with the
     * given <tt>title</tt>.
     * 
     * @param request
     *            the request of the current operation
     * @param response
     *            the response of the current operation
     * @param title
     *            the title of the page
     * 
     * @throws IOException 
     * @throws ServletException 
     */
    private void handleViewPageHistory(HttpServletRequest request,
            HttpServletResponse response, String title) throws ServletException, IOException {
        PageHistoryResult result = ScalarisDataHandler.getPageHistory(connection, title);
        if (result.not_existing) {
            handleViewPageNotExisting(request, response, title);
            return;
        }
        
        if (result.success) {
            WikiPageBean value = new WikiPageBean();
            value.setNotice(WikiServlet.getParam_notice(request));
            value.setRevisions(result.revisions);
            if (!result.page.checkEditAllowed("")) {
                value.setEditRestricted(true);
            }
            
            value.setTitle(title);
            if (!result.revisions.isEmpty()) { 
                value.setVersion(result.revisions.get(0).getId());
            }
            value.setWikiTitle(siteinfo.getSitename());
            value.setWikiNamespace(namespace);
            
            // forward the request and the bean to the jsp:
            request.setAttribute("pageBean", value);
            RequestDispatcher dispatcher = request
                    .getRequestDispatcher("pageHistory.jsp");
            dispatcher.forward(request, response);
        } else {
            addToParam_notice(request, "error: unknown error getting revision list for page " + title + ": <pre>" + result.message + "</pre>");
            showEmptyPage(request, response);
        }
    }

    /**
     * Shows a page containing a list of article names.
     * 
     * @param request
     *            the request of the current operation
     * @param response
     *            the response of the current operation
     * @param result
     *            result from reading the page list from Scalaris
     * @param value
     *            the page bean
     * 
     * @throws IOException
     * @throws ServletException
     */
    private void handleViewSpecialPageList(HttpServletRequest request,
            HttpServletResponse response, PageListResult result,
            WikiPageListBean value)
            throws ServletException, IOException {
        if (result.success) {
            value.setNotice(WikiServlet.getParam_notice(request));
            Collections.sort(result.pages, String.CASE_INSENSITIVE_ORDER);
            String nsPrefix = namespace.getNamespaceByNumber(value.getNamespaceId());
            if (!nsPrefix.isEmpty()) {
                nsPrefix += ":";
            }
            String prefix = nsPrefix + value.getPrefix();
            String from = value.getFromPage();
            String fullFrom = nsPrefix + value.getFromPage();
            String to = value.getToPage();
            String fullTo = nsPrefix + value.getToPage();
            if (!prefix.isEmpty() || !from.isEmpty() || !to.isEmpty()) {
                // only show pages with this prefix:
                for (Iterator<String> it = result.pages.iterator(); it.hasNext(); ) {
                    String cur = it.next();
                    // case-insensitive "startsWith" check:
                    if (!cur.regionMatches(true, 0, prefix, 0, prefix.length())) {
                        it.remove();
                    } else if (!from.isEmpty() && cur.compareToIgnoreCase(fullFrom) <= 0) {
                        it.remove();
                    } else if (!to.isEmpty() && cur.compareToIgnoreCase(fullTo) > 0) {
                        it.remove();
                    }
                }
            }
            value.setPages(result.pages);
            
            value.setWikiTitle(siteinfo.getSitename());
            value.setWikiNamespace(namespace);
            
            // forward the request and the bean to the jsp:
            request.setAttribute("pageBean", value);
            RequestDispatcher dispatcher = request
                    .getRequestDispatcher("pageSpecial_pagelist.jsp");
            dispatcher.forward(request, response);
        } else {
            addToParam_notice(request, "error: unknown error getting page list for " + value.getTitle() + ": <pre>" + result.message + "</pre>");
            showEmptyPage(request, response);
        }
    }

    private void handleViewSpecialPages(HttpServletRequest request,
            HttpServletResponse response) throws ServletException, IOException {
        WikiPageListBean value = new WikiPageListBean();
        value.setPageHeading("Special pages");
        value.setTitle("Special:SpecialPages");
        
        Map<String /*group*/, Map<String /*title*/, String /*description*/>> specialPages = new LinkedHashMap<String, Map<String, String>>();
        Map<String, String> curSpecialPages;
        // Lists of pages
        curSpecialPages = new LinkedHashMap<String, String>();
        curSpecialPages.put("Special:AllPages", "All pages");
        curSpecialPages.put("Special:PrefixIndex", "All pages with prefix");
        specialPages.put("Lists of pages", curSpecialPages);
        // Wiki data and tools
        curSpecialPages = new LinkedHashMap<String, String>();
        curSpecialPages.put("Special:Statistics", "Statistics");
        curSpecialPages.put("Special:Version", "Version");
        specialPages.put("Wiki data and tools", curSpecialPages);
        // Redirecting special pages
        curSpecialPages = new LinkedHashMap<String, String>();
        curSpecialPages.put("Special:Search", "Search");
        curSpecialPages.put("Special:Random", "Show any page");
        specialPages.put("Redirecting special pages", curSpecialPages);
        // Page tools
        curSpecialPages = new LinkedHashMap<String, String>();
        curSpecialPages.put("Special:WhatLinksHere", "What links here");
        specialPages.put("Page tools", curSpecialPages);

        StringBuilder content = new StringBuilder();
        for (Entry<String, Map<String, String>> specialPagesInGroup: specialPages.entrySet()) {
            String groupName = specialPagesInGroup.getKey();
            int i = 0;
            Iterator<Entry<String, String>> it = specialPagesInGroup.getValue().entrySet().iterator();
            
            content.append("<h4 class=\"mw-specialpagesgroup\"> <span class=\"mw-headline\">" + groupName + "</span></h4>\n");
            content.append("<table style=\"width: 100%;\" class=\"mw-specialpages-table\">\n");
            content.append(" <tbody>\n");
            content.append("  <tr>\n");
            content.append("   <td style=\"width: 30%; vertical-align: top;\">\n");
            content.append("    <ul>\n");
            int pagesInFirst = specialPagesInGroup.getValue().size() / 2 + specialPagesInGroup.getValue().size() % 2;
            for (; i < pagesInFirst; ++i) {
                Entry<String, String> page = it.next();
                content.append("<li><a href=\"wiki?title=" + page.getKey() + "\" title=\"" + page.getKey() + "\">" + page.getValue() + "</a></li>\n");
            }
            content.append("    </ul>\n");
            content.append("   </td>\n");
            content.append("   <td style=\"width: 10%;\"></td>\n");
            content.append("   <td style=\"width: 30%;\">\n");
            content.append("    <ul>\n");
            while(it.hasNext()) {
                Entry<String, String> page = it.next();
                content.append("<li><a href=\"wiki?title=" + page.getKey() + "\" title=\"" + page.getKey() + "\">" + page.getValue() + "</a></li>\n");
            }
            content.append("    </ul>\n");
            content.append("   </td>\n");
            content.append("   <td style=\"width: 30%;\"></td>\n");
            content.append("  </tr>\n");
            content.append(" </tbody>\n");
            content.append("</table>\n");
        }
        
        value.setPage(content.toString());
        // abuse #handleViewSpecialPageList here:
        PageListResult result = new PageListResult(new LinkedList<String>());
        handleViewSpecialPageList(request, response, result, value);
    }

    private void handleViewSpecialStatistics(HttpServletRequest request,
            HttpServletResponse response) throws ServletException, IOException {
        MyWikiModel wikiModel = getWikiModel();
        WikiPageListBean value = new WikiPageListBean();
        value.setPageHeading("Statistics");
        value.setTitle("Special:Statistics");

        BigInteger articleCount = ScalarisDataHandler.getArticleCount(connection).number;
        BigInteger pageCount = ScalarisDataHandler.getPageCount(connection).number;
        BigInteger uploadedFiles = BigInteger.valueOf(0); // TODO
        BigInteger pageEdits = ScalarisDataHandler.getStatsPageEdits(connection).number;
        double pageEditsPerPage = (pageCount.equals(BigInteger.valueOf(0))) ? 0.0 : pageEdits.doubleValue() / pageCount.doubleValue();
        
        Map<String /*group*/, Map<String /*name*/, String /*value*/>> specialPages = new LinkedHashMap<String, Map<String, String>>();
        Map<String, String> curStats;
        // Page statistics
        curStats = new LinkedHashMap<String, String>();
        curStats.put("Content pages", wikiModel.formatStatisticNumber(false, articleCount));
        curStats.put("Pages<br><small class=\"mw-statistic-desc\"> (All pages in the wiki, including talk pages, redirects, etc.)</small>",
                wikiModel.formatStatisticNumber(false, pageCount));
        curStats.put("Uploaded files", wikiModel.formatStatisticNumber(false, uploadedFiles));
        specialPages.put("Page statistics", curStats);
        // Edit statistics
        curStats = new LinkedHashMap<String, String>();
        curStats.put("Page edits since Wikipedia was set up", wikiModel.formatStatisticNumber(false, pageEdits));
        curStats.put("Average changes per page", wikiModel.formatStatisticNumber(false, pageEditsPerPage));
        specialPages.put("Edit statistics", curStats);
        // User statistics
        curStats = new LinkedHashMap<String, String>();
        specialPages.put("User statistics", curStats);

        StringBuilder content = new StringBuilder();
        content.append("<table class=\"wikitable mw-statistics-table\">\n");
        content.append(" <tbody>\n");
        for (Entry<String, Map<String, String>> specialPagesInGroup: specialPages.entrySet()) {
            String groupName = specialPagesInGroup.getKey();
            Iterator<Entry<String, String>> it = specialPagesInGroup.getValue().entrySet().iterator();
            
            content.append("  <tr>\n");
            content.append("   <th colspan=\"2\">" + groupName + "</th>\n");
            content.append("  </tr>\n");
            
            while(it.hasNext()) {
                Entry<String, String> page = it.next();
                content.append("  <tr class=\"mw-statistics\">\n");
                content.append("   <td>" + page.getKey() + "</td>\n");
                content.append("   <td class=\"mw-statistics-numbers\">" + page.getValue() + "</td>\n");
                content.append("  </tr>\n");
            }
        }
        content.append(" </tbody>\n");
        content.append("</table>\n");
        
        value.setPage(content.toString());
        // abuse #handleViewSpecialPageList here:
        PageListResult result = new PageListResult(new LinkedList<String>());
        handleViewSpecialPageList(request, response, result, value);
    }

    private void handleViewSpecialVersion(HttpServletRequest request,
            HttpServletResponse response) throws ServletException, IOException {
        WikiPageListBean value = new WikiPageListBean();
        value.setPageHeading("Version");
        value.setTitle("Special:Version");

        StringBuilder content = new StringBuilder();
        content.append("<h2 id=\"mw-version-license\"> <span class=\"mw-headline\" id=\"License\">License</span></h2>\n");
        content.append("<div>\n");
        content.append("<p>This wiki is powered by <b><a href=\"http://code.google.com/p/scalaris/\" class=\"external text\" rel=\"nofollow\">Scalaris</a></b>, copyright © 2011 Zuse Institute Berlin</p>\n");
        content.append("<p>\n");
        content.append(" Licensed under the Apache License, Version 2.0 (the \"License\");</br>\n");
        content.append(" you may not use this software except in compliance with the License.</br>\n");
        content.append(" &nbsp;</br>\n");
        content.append(" You may obtain a copy of the License at</br>\n");
        content.append(" <a href=\"http://www.apache.org/licenses/LICENSE-2.0\" class=\"external text\" rel=\"nofollow\">http://www.apache.org/licenses/LICENSE-2.0</a>\n");
        content.append("</p>\n");
        content.append("<p>\n");
        content.append(" Unless required by applicable law or agreed to in writing, software</br>\n");
        content.append(" distributed under the License is distributed on an \"AS IS\" BASIS,</br>\n");
        content.append(" WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.</br>\n");
        content.append(" See the License for the specific language governing permissions and</br>\n");
        content.append(" limitations under the License.\n");
        content.append("</p>\n");
        content.append("</div>");
        
        content.append("<h2 id=\"mw-version-software\"> <span class=\"mw-headline\" id=\"Installed_software\">Installed software</span></h2>\n");
        content.append("<table class=\"wikitable\" id=\"sv-software\">\n");
        content.append(" <tbody>\n");
        content.append("  <tr>\n");
        content.append("   <th>Product</th>\n");
        content.append("   <th>Version</th>\n");
        content.append("  </tr>\n");
        content.append("  <tr>\n");
        content.append("   <td><a href=\"http://code.google.com/p/scalaris/\" class=\"external text\" rel=\"nofollow\">Scalaris Wiki Example</a></td>\n");
        content.append("   <td>" + version + "</td>\n");
        content.append("  </tr>\n");
        content.append("  <tr>\n");
        content.append("   <td><a href=\"http://code.google.com/p/scalaris/\" class=\"external text\" rel=\"nofollow\">Scalaris</a></td>\n");
        content.append("   <td>???</td>\n"); // TODO: get Scalaris version
        content.append("  </tr>\n");
        content.append("  <tr>\n");
        content.append("   <td>Server</td>\n");
        content.append("   <td>" + getServletContext().getServerInfo() + "</td>\n");
        content.append("  </tr>\n");
        content.append(" </tbody>\n");
        content.append("</table>\n");
        
        value.setPage(content.toString());
        // abuse #handleViewSpecialPageList here:
        PageListResult result = new PageListResult(new LinkedList<String>());
        handleViewSpecialPageList(request, response, result, value);
    }
    
    /**
     * Shows an empty page for testing purposes.
     * 
     * @param request
     *            the request of the current operation
     * @param response
     *            the response of the current operation
     * 
     * @throws IOException 
     * @throws ServletException 
     */
    private void showEmptyPage(HttpServletRequest request,
            HttpServletResponse response) throws ServletException, IOException {
        WikiPageBean value = new WikiPageBean();
        value.setNotice(WikiServlet.getParam_notice(request));
        request.setAttribute("pageBean", value);
        RequestDispatcher dispatcher = request.getRequestDispatcher("page.jsp");
        dispatcher.forward(request, response);
    }
    
    /**
     * Shows an empty page for testing purposes.
     * 
     * @param request
     *            the request of the current operation
     * @param response
     *            the response of the current operation
     * 
     * @throws IOException 
     * @throws ServletException 
     */
    private void showImportPage(HttpServletRequest request,
            HttpServletResponse response) throws ServletException, IOException {
        WikiPageBean value = new WikiPageBean();
        value.setTitle("Import Wiki dump");
        value.setNotAvailable(true);
        request.setAttribute("pageBean", value);
        
        StringBuilder content = new StringBuilder();
        String dumpsPath = getServletContext().getRealPath("/WEB-INF/dumps");
        
        if (currentImport.isEmpty() || importHandler == null) {
            List<String> availableDumps = new LinkedList<String>();
            File dumpsDir = new File(dumpsPath);
            if (dumpsDir.isDirectory()) {
                availableDumps = Arrays.asList(dumpsDir.list(new FilenameFilter() {
                    @Override
                    public boolean accept(File dir, String name) {
                        return MATCH_WIKI_IMPORT_FILE.matcher(name).matches();
                    }
                }));
            }

            // get parameters:
            String req_import = request.getParameter("import");
            if (req_import == null || !availableDumps.contains(req_import)) {
                content.append("<h2>Please select a wiki dump to import</h2>\n");
                
                content.append("<form method=\"get\" action=\"wiki\">\n");
                content.append("<p>\n");
                content.append("  <select name=\"import\" size=\"10\" style=\"width:400px;\">\n");
                for (String dump: availableDumps) {
                    content.append("   <option>" + dump + "</option>\n");
                }
                content.append("  </select>\n");
                content.append(" </p>\n");
                content.append(" Maximum number of revisions per page: <input name=\"max_revisions\" size=\"2\" value=\"2\" /></br>\n");
                content.append(" <input type=\"submit\" value=\"Import\" />\n");
                content.append("</form>\n");
                content.append("<p>Note: You will be re-directed to the main page when the import finishes.</p>");
            } else {
                content.append("<h2>Importing \"" + req_import + "\"...</h2>\n");
                try {
                    currentImport = req_import;
                    int maxRevisions = parseInt(request.getParameter("max_revisions"), 2);
                    PrintStream ps = new PrintStream(new FileOutputStream(dumpsPath + File.separator + req_import + "-import.log"));
                    ps.println("starting import...");
                    importHandler = new WikiDumpToScalarisHandler(de.zib.scalaris.examples.wikipedia.data.xml.Main.blacklist, maxRevisions, cFactory);
                    importHandler.setUp();
                    importHandler.setMsgOut(ps);
                    InputSource is = de.zib.scalaris.examples.wikipedia.data.xml.Main.getFileReader(dumpsPath + File.separator + req_import);
                    XMLReader reader = XMLReaderFactory.createXMLReader();
                    reader.setContentHandler(importHandler);
                    this.new ImportThread(reader, importHandler, is, ps).start();
                    response.setHeader("Refresh", "2; url = wiki?import=" + currentImport);
                    content.append("<p>Current log file (refreshed automatically every " + IMPORT_REDIRECT_EVERY + " seconds):</p>\n");
                    content.append("<pre>");
                    content.append("starting import...\n");
                    content.append("</pre>");
                    content.append("<p><a href=\"wiki?import=" + currentImport + "\">refresh</a></p>");
                    content.append("<p><a href=\"wiki?stop_import=" + currentImport + "\">stop</a> (WARNING: pages may be incomplete due to missing templates)</p>");
                } catch (Exception e) {
                    addToParam_notice(request, "error: <pre>" + e.getMessage() + "</pre>");
                    currentImport = "";
                }
            }
        } else {
            content.append("<h2>Importing \"" + currentImport + "\"...</h2>\n");
            
            String req_stop_import = request.getParameter("stop_import");
            boolean stopImport;
            if (req_stop_import == null || req_stop_import.isEmpty()) {
                stopImport = false;
                response.setHeader("Refresh", IMPORT_REDIRECT_EVERY + "; url = wiki?import=" + currentImport);
                content.append("<p>Current log file (refreshed automatically every " + IMPORT_REDIRECT_EVERY + " seconds):</p>\n");
            } else {
                stopImport = true;
                importHandler.stopParsing();
                content.append("<p>Current log file:</p>\n");
            }
            content.append("<pre>");
            final String logFileName = dumpsPath + File.separator + currentImport + "-import.log";
            BufferedReader br = new BufferedReader(new InputStreamReader(new FileInputStream(logFileName), "UTF-8"));
            String line;
            while ((line = br.readLine()) != null) {
                content.append(line);
                content.append("\n");
            }
            content.append("</pre>");
            if (!stopImport) {
                content.append("<p><a href=\"wiki?import=" + currentImport + "\">refresh</a></p>");
                content.append("<p><a href=\"wiki?stop_import=" + currentImport + "\">stop</a> (WARNING: pages may be incomplete due to missing templates)</p>");
            } else {
                content.append("<p>Import has been stopped by the user. Return to <a href=\"wiki?title=" + MAIN_PAGE + "\">" + MAIN_PAGE + "</a>.</p>");
            }
        }

        value.setNotice(WikiServlet.getParam_notice(request));
        value.setPage(content.toString());
        
        RequestDispatcher dispatcher = request.getRequestDispatcher("page.jsp");
        dispatcher.forward(request, response);
    }
    
    class ImportThread extends Thread {
        private XMLReader reader;
        private WikiDumpHandler handler;
        private InputSource is;
        private PrintStream ps;
        
        public ImportThread(XMLReader reader, WikiDumpHandler handler, InputSource is, PrintStream ps) {
            this.reader = reader;
            this.handler = handler;
            this.is = is;
            this.ps = ps;
        }
        /* (non-Javadoc)
         * @see java.lang.Thread#run()
         */
        @Override
        public void run() {
            try {
                reader.parse(is);
                handler.tearDown();
                ps.println("import finished");
            } catch (Exception e) {
                if (e instanceof SAXParsingInterruptedException) {
                    // this is ok - we told the parser to stop
                } else {
                    e.printStackTrace(ps);
                }
            }
            WikiServlet.this.currentImport = "";
        }
    }

    /**
     * Shows the edit page form for an article with the given <tt>title</tt>.
     * 
     * @param request
     *            the request of the current operation
     * @param response
     *            the response of the current operation
     * @param title
     *            the title of the article to show
     *            
     * @throws IOException 
     * @throws ServletException 
     */
    private void handleEditPage(HttpServletRequest request,
            HttpServletResponse response, String title) throws ServletException, IOException {
        // get revision id to load:
        int req_oldid = WikiServlet.getParam_oldid(request);

        WikiPageEditBean value = new WikiPageEditBean();
        RevisionResult result = ScalarisDataHandler.getRevision(connection, title, req_oldid);
        if (result.rev_not_existing) {
            result = ScalarisDataHandler.getRevision(connection, title);
            addToParam_notice(request, "revision " + req_oldid + " not found - loaded current revision instead");
        }

        if (result.page_not_existing) {
            value.setVersion(-1);
            value.setNewPage(true);
        } else if (result.rev_not_existing) {
            // DB corrupt
            addToParam_notice(request, "error: unknown error getting current revision of page \"" + title + "\": <pre>" + result.message + "</pre>");
            showEmptyPage(request, response);
            return;
        }
        if (result.success) {
            if (!result.page.checkEditAllowed("")) {
                value.setEditRestricted(true);
            }
            value.setPage(StringEscapeUtils.escapeHtml(result.revision.getText()));
            value.setVersion(result.revision.getId());
        }

        // set the textarea's contents:
        value.setNotice(WikiServlet.getParam_notice(request));
        value.setTitle(title);
        value.setWikiTitle(siteinfo.getSitename());
        value.setWikiNamespace(namespace);

        // forward the request and the bean to the jsp:
        request.setAttribute("pageBean", value);
        RequestDispatcher dispatcher = request
                .getRequestDispatcher("pageEdit.jsp");
        dispatcher.forward(request, response);
    }
    
    /**
     * Shows a preview of the edit operation submitted or saves the page with
     * the given <tt>title</tt> depending on what button the user clicked.
     * 
     * @param request
     *            the request of the current operation
     * @param response
     *            the response of the current operation
     * @param title
     *            the title of the article to show
     * 
     * @throws IOException 
     * @throws UnsupportedEncodingException 
     * @throws ServletException 
     */
    private void handleEditPageSubmitted(HttpServletRequest request,
            HttpServletResponse response, String title) throws UnsupportedEncodingException, IOException, ServletException {
        String content = request.getParameter("wpTextbox1");
        String summary = request.getParameter("wpSummary");
        int oldVersion = parseInt(request.getParameter("oldVersion"), -1);
        boolean minorChange = Boolean.parseBoolean(request.getParameter("minor"));

        // save page or preview+edit page?
        if (request.getParameter("wpSave") != null) {
            // save page
            Contributor contributor = new Contributor();
            contributor.setIp(request.getRemoteAddr());
            String timestamp = Revision.calendarToString(Calendar.getInstance(TimeZone.getTimeZone("UTC")));
            int newRevId = (oldVersion == -1) ? 1 : oldVersion + 1;
            Revision newRev = new Revision(newRevId, timestamp, minorChange, contributor, summary, content);

            SavePageResult result = ScalarisDataHandler.savePage(connection, title, newRev, oldVersion, null, siteinfo, "");
            for (WikiEventHandler handler: eventHandlers) {
                handler.onPageSaved(result);
            }
            if (result.success) {
                // successfully saved -> show page with a notice of the successful operation
                // do not include the UTF-8-title directly into encodeRedirectURL since that's not 
                // encoding umlauts (maybe other special chars as well) correctly, e.g. ä -> %E4 instead of %C3%A4
                response.sendRedirect(response.encodeRedirectURL("?title=" + URLEncoder.encode(title, "UTF-8") + "&notice=successfully saved page"));
                return;
            } else {
                // set error message and show the edit page again (see below)
                addToParam_notice(request, "error: could not save page: <pre>" + result.message + "</pre>");
            }
        }

        // preview+edit page

        WikiPageEditBean value = new WikiPageEditBean();
        value.setNotice(WikiServlet.getParam_notice(request));
        // set the textarea's contents:
        value.setPage(StringEscapeUtils.escapeHtml(content));

        MyWikiModel wikiModel = getWikiModel();
        wikiModel.setPageName(title);
        String fullUrl = extractFullUrl(request.getRequestURL().toString());
        if (fullUrl != null) {
            wikiModel.setLinkBaseFullURL(fullUrl);
        }
        value.setPreview(wikiModel.render(content));
        value.setPage(content);
        value.setVersion(oldVersion);
        value.setTitle(title);
        value.setSummary(request.getParameter("wpSummary"));
        value.setWikiTitle(siteinfo.getSitename());
        value.setWikiNamespace(namespace);

        // forward the request and the bean to the jsp:
        request.setAttribute("pageBean", value);
        RequestDispatcher dispatcher = request
                .getRequestDispatcher("pageEdit.jsp");
        dispatcher.forward(request, response);
    }
    
    private MyWikiModel getWikiModel() {
        return new MyWikiModel(WikiServlet.imageBaseURL,
                WikiServlet.linkBaseURL, connection, namespace);
    }

    /**
     * Adds the given notice to the notice attribute .
     * 
     * @param request
     *            the http request
     * @param notice
     *            the notice to add
     */
    public static void addToParam_notice(HttpServletRequest request, String notice) {
        String req_notice = getParam_notice(request);
        String new_notice = req_notice.isEmpty() ? notice : req_notice + "<br />" + notice;
        request.setAttribute("notice", new_notice);
    }

    /**
     * Returns the notice parameter (or attribute if the parameter does not exist) or an empty string if both are not present
     * 
     * @param request
     *            the http request
     * @return the notice parameter or ""
     */
    public static String getParam_notice(HttpServletRequest request) {
        String req_notice = request.getParameter("notice");
        if (req_notice == null) {
            Object temp = request.getAttribute("notice");
            if (temp instanceof String) {
                req_notice = (String) temp; 
            }
        }
        if (req_notice == null) {
            return new String("");
        } else {
            return req_notice;
        }
    }

    /**
     * Get the revision id to load from the request object
     * 
     * @param request
     *            the http request
     * @return the revision id or -1 on failure to parse
     */
    private static int getParam_oldid(HttpServletRequest request) {
        String req_oldid = request.getParameter("oldid");
        return parseInt(req_oldid, -1);
    }

    /**
     * Determines which renderer should be used by evaluating the render
     * parameter of the request
     * 
     * @param request
     *            the http request
     * @return the renderer id
     */
    private static int getParam_renderer(HttpServletRequest request) {
        int render = 1;
        String req_render = request.getParameter("render");
        if (req_render == null) {
            // already set to 1, so the default renderer is used
        } else if (req_render.equals("0")) {
            render = 0;
        } else if (req_render.equals("-1")) {
            render = -1;
        }
        return render;
    }
    
    private final static int parseInt(String value, int def) {
        if (value == null) {
            return def;
        }
        try {
            return Integer.parseInt(value);
        } catch (NumberFormatException e) {
            return def;
        }
    }

    /* (non-Javadoc)
     * @see de.zib.scalaris.examples.wikipedia.bliki.WikiServletInterface#getNamespace()
     */
    @Override
    public final NamespaceUtils getNamespace() {
        return namespace;
    }

    /* (non-Javadoc)
     * @see de.zib.scalaris.examples.wikipedia.bliki.WikiServletInterface#getSiteinfo()
     */
    @Override
    public SiteInfo getSiteinfo() {
        return siteinfo;
    }

    /* (non-Javadoc)
     * @see de.zib.scalaris.examples.wikipedia.bliki.WikiServletInterface#getVersion()
     */
    @Override
    public String getVersion() {
        return version;
    }

    /* (non-Javadoc)
     * @see de.zib.scalaris.examples.wikipedia.bliki.WikiServletInterface#getWikibaseurl()
     */
    @Override
    public String getWikibaseurl() {
        return wikiBaseURL;
    }

    /* (non-Javadoc)
     * @see de.zib.scalaris.examples.wikipedia.bliki.WikiServletInterface#getLinkbaseurl()
     */
    @Override
    public String getLinkbaseurl() {
        return linkBaseURL;
    }

    /* (non-Javadoc)
     * @see de.zib.scalaris.examples.wikipedia.bliki.WikiServletInterface#getImagebaseurl()
     */
    @Override
    public String getImagebaseurl() {
        return imageBaseURL;
    }

    /* (non-Javadoc)
     * @see de.zib.scalaris.examples.wikipedia.bliki.WikiServletInterface#getImagebaseurl()
     */
    @Override
    public void registerEventHandler(WikiEventHandler handler) {
        eventHandlers.add(handler);
    }
}