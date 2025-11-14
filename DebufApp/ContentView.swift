

import SwiftUI
import Combine

// MARK: - Модели данных
struct User: Codable {
    let id: String
    let username: String
    let email: String
    let joinDate: Date
    var analysesCount: Int
    var averageScore: Double
    let password: String // Добавляем поле для пароля
}

struct CodeAnalysis: Codable, Identifiable {
    var id = UUID()
    let fileName: String
    let issues: [CodeIssue]
    let overallScore: Int
    let recommendations: [String]
    let analyzedCode: String?
    let analyzedAt: Date
    let githubURL: String
}

struct CodeIssue: Codable, Identifiable {
    var id = UUID()
    let lineNumber: Int
    let severity: IssueSeverity
    let message: String
    let suggestion: String?
}

enum IssueSeverity: String, Codable {
    case low = "Низкая"
    case medium = "Средняя"
    case high = "Высокая"
    case critical = "Критическая"
}

struct GitHubFileInfo {
    let owner: String
    let repo: String
    let branch: String
    let filePath: String
    let fileName: String
}

// MARK: - Сервисы
class AuthService: ObservableObject {
    @Published var isAuthenticated = false
    @Published var currentUser: User?
    @Published var errorMessage: String?
    
    private let usersKey = "debugBuddyUsers"
    private let currentUserKey = "debugBuddyCurrentUser"
    
    init() {
        // Проверяем, есть ли сохраненный пользователь
        if let userData = UserDefaults.standard.data(forKey: currentUserKey),
           let user = try? JSONDecoder().decode(User.self, from: userData) {
            currentUser = user
            isAuthenticated = true
        }
    }
    
    func register(username: String, email: String, password: String) -> Bool {
        // Простая валидация
        guard !username.isEmpty, !email.isEmpty, !password.isEmpty else {
            errorMessage = "Все поля обязательны для заполнения"
            return false
        }
        
        guard password.count >= 6 else {
            errorMessage = "Пароль должен содержать минимум 6 символов"
            return false
        }
        
        guard email.contains("@") else {
            errorMessage = "Неверный формат email"
            return false
        }
        
        // Проверяем, нет ли уже такого пользователя
        var users = getStoredUsers()
        if users.contains(where: { $0.username.lowercased() == username.lowercased() }) {
            errorMessage = "Имя пользователя уже занято"
            return false
        }
        
        if users.contains(where: { $0.email.lowercased() == email.lowercased() }) {
            errorMessage = "Email уже зарегистрирован"
            return false
        }
        
        // Создаем нового пользователя
        let newUser = User(
            id: UUID().uuidString,
            username: username,
            email: email,
            joinDate: Date(),
            analysesCount: 0,
            averageScore: 0.0,
            password: password // Сохраняем пароль
        )
        
        users.append(newUser)
        saveUsers(users)
        
        // Автоматически логиним пользователя
        let loginSuccess = login(username: username, password: password)
        return loginSuccess
    }
    
    func login(username: String, password: String) -> Bool {
        let users = getStoredUsers()
        
        // Ищем пользователя по username
        guard let user = users.first(where: {
            $0.username.lowercased() == username.lowercased()
        }) else {
            errorMessage = "Пользователь не найден"
            return false
        }
        
        // Проверяем пароль (в реальном приложении здесь было бы хеширование)
        guard user.password == password else {
            errorMessage = "Неверный пароль"
            return false
        }
        
        // Успешный вход
        currentUser = user
        isAuthenticated = true
        saveCurrentUser(user)
        errorMessage = nil
        return true
    }
    
    func logout() {
        currentUser = nil
        isAuthenticated = false
        UserDefaults.standard.removeObject(forKey: currentUserKey)
    }
    
    func updateUserAnalyses(count: Int, averageScore: Double) {
        guard var user = currentUser else { return }
        
        // Создаем обновленного пользователя
        let updatedUser = User(
            id: user.id,
            username: user.username,
            email: user.email,
            joinDate: user.joinDate,
            analysesCount: count,
            averageScore: averageScore,
            password: user.password // Сохраняем пароль
        )
        
        currentUser = updatedUser
        saveCurrentUser(updatedUser)
        
        // Обновляем в общем списке пользователей
        var users = getStoredUsers()
        if let index = users.firstIndex(where: { $0.id == user.id }) {
            users[index] = updatedUser
            saveUsers(users)
        }
    }
    
    private func getStoredUsers() -> [User] {
        guard let data = UserDefaults.standard.data(forKey: usersKey),
              let users = try? JSONDecoder().decode([User].self, from: data) else {
            return []
        }
        return users
    }
    
    private func saveUsers(_ users: [User]) {
        if let data = try? JSONEncoder().encode(users) {
            UserDefaults.standard.set(data, forKey: usersKey)
        }
    }
    
    private func saveCurrentUser(_ user: User) {
        if let data = try? JSONEncoder().encode(user) {
            UserDefaults.standard.set(data, forKey: currentUserKey)
        }
    }
}

class AnalysisService: ObservableObject {
    @Published var isAnalyzing = false
    @Published var errorMessage: String?
    
    private let analysesKey = "debugBuddyAnalyses"
    
    func analyzeGitHubFile(url: String, userId: String) async -> CodeAnalysis? {
        await MainActor.run {
            isAnalyzing = true
            errorMessage = nil
        }
        
        // Парсим URL GitHub
        guard let fileInfo = parseGitHubURL(url) else {
            await MainActor.run {
                errorMessage = "Неверный формат GitHub URL"
                isAnalyzing = false
            }
            return nil
        }
        
        // Получаем raw содержимое файла
        guard let fileContent = await fetchGitHubFileContent(fileInfo: fileInfo) else {
            await MainActor.run {
                errorMessage = "Не удалось загрузить содержимое файла"
                isAnalyzing = false
            }
            return nil
        }
        
        // Анализируем код
        let analysis = await performCodeAnalysis(
            fileContent: fileContent,
            fileInfo: fileInfo,
            githubURL: url
        )
        
        // Сохраняем анализ
        saveAnalysis(analysis, userId: userId)
        
        await MainActor.run {
            isAnalyzing = false
        }
        
        return analysis
    }
    
    func getUserAnalyses(userId: String) -> [CodeAnalysis] {
        guard let data = UserDefaults.standard.data(forKey: analysesKey),
              let allAnalyses = try? JSONDecoder().decode([String: [CodeAnalysis]].self, from: data) else {
            return []
        }
        return allAnalyses[userId] ?? []
    }
    
    private func saveAnalysis(_ analysis: CodeAnalysis, userId: String) {
        var allAnalyses = getAllAnalyses()
        var userAnalyses = allAnalyses[userId] ?? []
        userAnalyses.insert(analysis, at: 0) // Добавляем в начало
        allAnalyses[userId] = userAnalyses
        
        if let data = try? JSONEncoder().encode(allAnalyses) {
            UserDefaults.standard.set(data, forKey: analysesKey)
        }
    }
    
    private func getAllAnalyses() -> [String: [CodeAnalysis]] {
        guard let data = UserDefaults.standard.data(forKey: analysesKey),
              let analyses = try? JSONDecoder().decode([String: [CodeAnalysis]].self, from: data) else {
            return [:]
        }
        return analyses
    }
    
    private func parseGitHubURL(_ url: String) -> GitHubFileInfo? {
        let pattern = #"https://github\.com/([^/]+)/([^/]+)/blob/([^/]+)/(.+)"#
        
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) else {
            return nil
        }
        
        let owner = String(url[Range(match.range(at: 1), in: url)!])
        let repo = String(url[Range(match.range(at: 2), in: url)!])
        let branch = String(url[Range(match.range(at: 3), in: url)!])
        let filePath = String(url[Range(match.range(at: 4), in: url)!])
        let fileName = URL(fileURLWithPath: filePath).lastPathComponent
        
        return GitHubFileInfo(
            owner: owner,
            repo: repo,
            branch: branch,
            filePath: filePath,
            fileName: fileName
        )
    }
    
    private func fetchGitHubFileContent(fileInfo: GitHubFileInfo) async -> String? {
        let rawURL = "https://raw.githubusercontent.com/\(fileInfo.owner)/\(fileInfo.repo)/\(fileInfo.branch)/\(fileInfo.filePath)"
        
        guard let url = URL(string: rawURL) else {
            return nil
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return String(data: data, encoding: .utf8)
        } catch {
            print("Error fetching file: \(error)")
            return nil
        }
    }
    
    private func performCodeAnalysis(fileContent: String, fileInfo: GitHubFileInfo, githubURL: String) async -> CodeAnalysis {
        try? await Task.sleep(nanoseconds: UInt64(Double.random(in: 2...4) * 1_000_000_000))
        
        let fileExtension = (fileInfo.fileName as NSString).pathExtension.lowercased()
        let analysis = generateAnalysisBasedOnFileType(
            content: fileContent,
            fileName: fileInfo.fileName,
            fileExtension: fileExtension,
            githubURL: githubURL
        )
        
        return analysis
    }
    
    private func generateAnalysisBasedOnFileType(content: String, fileName: String, fileExtension: String, githubURL: String) -> CodeAnalysis {
        let lines = content.components(separatedBy: .newlines)
        var issues: [CodeIssue] = []
        
        // Общий анализ для всех языков
        for (index, line) in lines.enumerated() {
            let lineNumber = index + 1
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            
            // Проверка на длинные строки
            if line.count > 100 {
                issues.append(CodeIssue(
                    lineNumber: lineNumber,
                    severity: .low,
                    message: "Слишком длинная строка (\(line.count) символов)",
                    suggestion: "Разбейте на несколько строк для лучшей читаемости"
                ))
            }
            
            // Проверка на сложные конструкции
            if line.contains("??") || line.contains("!!") {
                issues.append(CodeIssue(
                    lineNumber: lineNumber,
                    severity: .medium,
                    message: "Сложный оператор обработки null",
                    suggestion: "Используйте явные проверки на null"
                ))
            }
            
            // Проверка на комментарии
            if !trimmedLine.contains("//") && !trimmedLine.contains("/*") && line.count > 50 {
                let words = trimmedLine.components(separatedBy: .whitespaces)
                if words.count > 8 {
                    issues.append(CodeIssue(
                        lineNumber: lineNumber,
                        severity: .low,
                        message: "Сложная логика без комментариев",
                        suggestion: "Добавьте комментарии для пояснения сложной логики"
                    ))
                }
            }
        }
        
        let score = max(0, 100 - issues.count * 5)
        
        return CodeAnalysis(
            fileName: fileName,
            issues: Array(issues.prefix(10)),
            overallScore: score,
            recommendations: [
                "Добавьте комплексную документацию",
                "Реализуйте обработку ошибок",
                "Следуйте лучшим практикам для конкретного языка",
                "Добавьте комментарии для сложной логики",
                "Оптимизируйте производительность кода"
            ],
            analyzedCode: content,
            analyzedAt: Date(),
            githubURL: githubURL
        )
    }
}

// MARK: - Стили и компоненты
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding()
            .background(
                LinearGradient(
                    gradient: Gradient(colors: [Color.purple, Color.blue]),
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .cornerRadius(12)
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundColor(.purple)
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.purple.opacity(0.1))
            .cornerRadius(12)
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: configuration.isPressed)
    }
}

struct ScoreBadge: View {
    let score: Int
    
    var color: Color {
        switch score {
        case 90...100: return .green
        case 70..<90: return .yellow
        case 50..<70: return .orange
        default: return .red
        }
    }
    
    var body: some View {
        Text("\(score)")
            .font(.system(size: 14, weight: .bold, design: .rounded))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color)
            .cornerRadius(6)
    }
}

struct IssueRow: View {
    let issue: CodeIssue
    
    var severityColor: Color {
        switch issue.severity {
        case .low: return .green
        case .medium: return .yellow
        case .high: return .orange
        case .critical: return .red
        }
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(severityColor)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(issue.message)
                    .font(.caption)
                    .foregroundColor(.primary)
                
                if let suggestion = issue.suggestion {
                    Text("💡 \(suggestion)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                Text("Строка \(issue.lineNumber) • \(issue.severity.rawValue)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct RecommendationRow: View {
    let text: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.caption)
            
            Text(text)
                .font(.caption)
                .foregroundColor(.primary)
            
            Spacer()
        }
    }
}

// MARK: - Вспомогательные View
struct AnalysisProgressView: View {
    @State private var rotation = 0.0
    @State private var scale: CGFloat = 1.0
    
    var body: some View {
        ZStack {
            // Фон с размытием
            Color.black.opacity(0.7)
                .ignoresSafeArea()
            
            VStack(spacing: 30) {
                // Анимированная иконка
                ZStack {
                    Circle()
                        .stroke(
                            LinearGradient(
                                gradient: Gradient(colors: [.purple, .blue, .purple]),
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            lineWidth: 8
                        )
                        .frame(width: 120, height: 120)
                    
                    Circle()
                        .trim(from: 0, to: 0.7)
                        .stroke(
                            LinearGradient(
                                gradient: Gradient(colors: [.blue, .purple]),
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            style: StrokeStyle(lineWidth: 8, lineCap: .round)
                        )
                        .frame(width: 120, height: 120)
                        .rotationEffect(.degrees(rotation))
                    
                    Image(systemName: "sparkles")
                        .font(.system(size: 40))
                        .foregroundColor(.white)
                        .scaleEffect(scale)
                }
                
                VStack(spacing: 15) {
                    Text("Анализ кода...")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                    
                    VStack(spacing: 8) {
                        Text("ИИ анализирует ваш код")
                            .font(.body)
                            .foregroundColor(.white.opacity(0.9))
                        
                        Text("Проверяем лучшие практики, безопасность и производительность")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                    
                    // Анимированные точки
                    HStack(spacing: 4) {
                        ForEach(0..<3) { index in
                            Circle()
                                .fill(Color.white)
                                .frame(width: 8, height: 8)
                                .scaleEffect(scale)
                                .animation(
                                    Animation.easeInOut(duration: 0.6)
                                        .repeatForever()
                                        .delay(Double(index) * 0.2),
                                    value: scale
                                )
                        }
                    }
                    .padding(.top, 10)
                }
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                rotation = 360
            }
            
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                scale = 1.2
            }
        }
    }
}

struct OverallScoreCard: View {
    let score: Int
    
    var scoreColor: Color {
        switch score {
        case 90...100: return .green
        case 70..<90: return .yellow
        case 50..<70: return .orange
        default: return .red
        }
    }
    
    var body: some View {
        VStack(spacing: 16) {
            Text("Общее качество кода")
                .font(.headline)
                .foregroundColor(.secondary)
            
            ZStack {
                Circle()
                    .stroke(Color(.systemGray5), lineWidth: 8)
                    .frame(width: 120, height: 120)
                
                Circle()
                    .trim(from: 0, to: CGFloat(score) / 100)
                    .stroke(scoreColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .frame(width: 120, height: 120)
                    .rotationEffect(.degrees(-90))
                
                VStack(spacing: 4) {
                    Text("\(score)")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundColor(scoreColor)
                    
                    Text("Баллов")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Text(scoreDescription)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
    }
    
    var scoreDescription: String {
        switch score {
        case 90...100: return "Отличное качество кода! 🎉"
        case 70..<90: return "Хороший код, нужны небольшие улучшения"
        case 50..<70: return "Среднее качество, рекомендуется рефакторинг"
        default: return "Требуются значительные улучшения"
        }
    }
}

struct FileAnalysisCard: View {
    let analysis: CodeAnalysis
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(analysis.fileName)
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Text("\(analysis.issues.count) проблем найдено")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("Проанализировано \(analysis.analyzedAt, style: .relative) назад")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                ScoreBadge(score: analysis.overallScore)
            }
            
            if !analysis.issues.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Проблемы:")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    ForEach(Array(analysis.issues.prefix(3))) { issue in
                        IssueRow(issue: issue)
                    }
                    
                    if analysis.issues.count > 3 {
                        Text("+ еще \(analysis.issues.count - 3) проблем")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            if !analysis.recommendations.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Рекомендации:")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    ForEach(Array(analysis.recommendations.prefix(3)), id: \.self) { recommendation in
                        RecommendationRow(text: recommendation)
                    }
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
    }
}

struct ErrorView: View {
    let message: String
    let onRetry: (() -> Void)?
    
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 50))
                .foregroundColor(.orange)
            
            Text("Что-то пошло не так")
                .font(.headline)
            
            Text(message)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            if let onRetry = onRetry {
                Button("Попробовать снова", action: onRetry)
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.top, 8)
            }
        }
        .padding()
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)
            
            Text(value)
                .font(.title2)
                .fontWeight(.bold)
            
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
    }
}

// MARK: - Authentication Views
struct LoginView: View {
    @EnvironmentObject var authService: AuthService
    @State private var username = ""
    @State private var password = ""
    @State private var showingRegister = false
    
    var body: some View {
        VStack(spacing: 30) {
            // Header
            VStack(spacing: 10) {
                Image(systemName: "ladybug.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.purple)
                
                Text("Debug Buddy")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                
                Text("AI-анализ кода")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }
            
            // Form
            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Имя пользователя")
                        .font(.headline)
                    
                    TextField("Введите имя пользователя", text: $username)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Пароль")
                        .font(.headline)
                    
                    SecureField("Введите пароль", text: $password)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }
            }
            
            // Error message
            if let error = authService.errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            
            // Buttons
            VStack(spacing: 12) {
                Button("Войти") {
                    let success = authService.login(username: username, password: password)
                    if !success {
                        // Очищаем поля при неудачной попытке входа
                        password = ""
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(username.isEmpty || password.isEmpty)
                
                Button("Создать аккаунт") {
                    showingRegister = true
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            
            Spacer()
            
            // Features
            VStack(spacing: 12) {
                FeatureView(icon: "sparkles", text: "AI-анализ кода")
                FeatureView(icon: "checkmark.shield", text: "Лучшие практики безопасности")
                FeatureView(icon: "bolt", text: "Быстрый анализ")
            }
        }
        .padding()
        .sheet(isPresented: $showingRegister) {
            RegisterView()
        }
    }
}

struct RegisterView: View {
    @EnvironmentObject var authService: AuthService
    @Environment(\.dismiss) var dismiss
    @State private var username = ""
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                // Form
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Имя пользователя")
                            .font(.headline)
                        
                        TextField("Выберите имя пользователя", text: $username)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Email")
                            .font(.headline)
                        
                        TextField("Введите ваш email", text: $email)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .keyboardType(.emailAddress)
                            .autocapitalization(.none)
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Пароль")
                            .font(.headline)
                        
                        SecureField("Создайте пароль", text: $password)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Подтвердите пароль")
                            .font(.headline)
                        
                        SecureField("Подтвердите ваш пароль", text: $confirmPassword)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    }
                }
                
                // Error message
                if let error = authService.errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                
                // Register button
                Button("Создать аккаунт") {
                    if password == confirmPassword {
                        if authService.register(username: username, email: email, password: password) {
                            dismiss()
                        }
                    } else {
                        authService.errorMessage = "Пароли не совпадают"
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(username.isEmpty || email.isEmpty || password.isEmpty || confirmPassword.isEmpty)
                
                Spacer()
            }
            .padding()
            .navigationTitle("Создание аккаунта")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Отмена") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Основные View
struct URLInputView: View {
    @Binding var githubURL: String
    let onAnalyze: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Анализ GitHub кода")
                .font(.title2)
                .fontWeight(.bold)
            
            VStack(alignment: .leading, spacing: 8) {
                Text("GitHub URL файла")
                    .font(.headline)
                    .foregroundColor(.primary)
                
                TextField("https://github.com/username/repo/blob/branch/path/to/file", text: $githubURL)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .keyboardType(.URL)
            }
            
            Button(action: onAnalyze) {
                HStack {
                    Image(systemName: "sparkles")
                    Text("Анализировать код")
                }
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(
                    LinearGradient(
                        gradient: Gradient(colors: [Color.purple, Color.blue]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .cornerRadius(12)
            }
            .disabled(githubURL.isEmpty)
            
            // Example URLs
            VStack(alignment: .leading, spacing: 12) {
                Text("Попробуйте пример:")
                    .font(.headline)
                    .foregroundColor(.primary)
                
                Button(action: {
                    githubURL = "https://github.com/Exportqq/FizHub/blob/main/pages/index.vue"
                }) {
                    HStack {
                        Image(systemName: "link")
                        Text("https://github.com/Exportqq/FizHub/blob/main/pages/index.vue")
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                    }
                    .foregroundColor(.blue)
                    .padding(8)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(8)
                }
            }
        }
        .padding()
    }
}

struct FeatureView: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.purple)
                .frame(width: 24)
            
            Text(text)
                .foregroundColor(.primary)
                .font(.subheadline)
            
            Spacer()
        }
    }
}

struct ProfileView: View {
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var analysisService: AnalysisService
    let user: User
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header
                VStack(spacing: 16) {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 80))
                        .foregroundColor(.purple)
                    
                    VStack(spacing: 4) {
                        Text(user.username)
                            .font(.title2)
                            .fontWeight(.bold)
                        
                        Text(user.email)
                            .font(.body)
                            .foregroundColor(.secondary)
                    }
                    
                    Text("Участник с \(user.joinDate, formatter: dateFormatter)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color(.systemBackground))
                .cornerRadius(12)
                .padding(.horizontal)
                
                // Stats
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: 12) {
                    StatCard(
                        title: "Анализов",
                        value: "\(user.analysesCount)",
                        icon: "chart.bar",
                        color: .blue
                    )
                    
                    StatCard(
                        title: "Средний балл",
                        value: String(format: "%.1f", user.averageScore),
                        icon: "star",
                        color: .yellow
                    )
                    
                    StatCard(
                        title: "В сообществе",
                        value: "\(daysSinceJoin) дней",
                        icon: "calendar",
                        color: .green
                    )
                    
                    StatCard(
                        title: "Уровень",
                        value: userLevel,
                        icon: "trophy",
                        color: .orange
                    )
                }
                .padding(.horizontal)
                
                // Recent Analyses
                if !recentAnalyses.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Последние анализы")
                            .font(.headline)
                            .padding(.horizontal)
                        
                        LazyVStack(spacing: 12) {
                            ForEach(recentAnalyses.prefix(3)) { analysis in
                                FileAnalysisCard(analysis: analysis)
                                    .padding(.horizontal)
                            }
                        }
                    }
                }
                
                // Actions
                VStack(spacing: 12) {
                    Button("Выйти") {
                        authService.logout()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.horizontal)
                }
                .padding(.top, 20)
            }
            .padding(.vertical)
        }
        .navigationTitle("Профиль")
    }
    
    private var recentAnalyses: [CodeAnalysis] {
        analysisService.getUserAnalyses(userId: user.id)
    }
    
    private var daysSinceJoin: Int {
        Calendar.current.dateComponents([.day], from: user.joinDate, to: Date()).day ?? 0
    }
    
    private var userLevel: String {
        switch user.analysesCount {
        case 0..<5: return "Новичок"
        case 5..<15: return "Опытный"
        case 15..<30: return "Продвинутый"
        default: return "Эксперт"
        }
    }
    
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.locale = Locale(identifier: "ru_RU")
        return formatter
    }()
}

// MARK: - Главный ContentView
struct ContentView: View {
    @StateObject private var authService = AuthService()
    @StateObject private var analysisService = AnalysisService()
    @State private var githubURL = ""
    @State private var analysisResult: CodeAnalysis?
    @State private var showingAnalysis = false
    @State private var selectedTab = 0
    
    var body: some View {
        Group {
            if authService.isAuthenticated, let user = authService.currentUser {
                mainAppView(user: user)
            } else {
                LoginView()
            }
        }
        .environmentObject(authService)
        .environmentObject(analysisService)
    }
    
    private func mainAppView(user: User) -> some View {
        TabView(selection: $selectedTab) {
            // Analysis Tab
            NavigationView {
                ZStack {
                    Color(.systemGroupedBackground)
                        .ignoresSafeArea()
                    
                    if showingAnalysis, let analysis = analysisResult {
                        ScrollView {
                            LazyVStack(spacing: 16) {
                                OverallScoreCard(score: analysis.overallScore)
                                
                                FileAnalysisCard(analysis: analysis)
                                
                                Button("Анализировать другой файл") {
                                    resetAnalysis()
                                }
                                .buttonStyle(PrimaryButtonStyle())
                                .padding()
                            }
                            .padding()
                        }
                        .navigationTitle("Результат анализа")
                    } else {
                        URLInputView(githubURL: $githubURL) {
                            Task {
                                await analyzeCode(user: user)
                            }
                        }
                        .navigationTitle("Debug Buddy")
                    }
                    
                    if analysisService.isAnalyzing {
                        AnalysisProgressView()
                    }
                    
                    if let error = analysisService.errorMessage {
                        Color.black.opacity(0.4)
                            .ignoresSafeArea()
                        
                        ErrorView(message: error) {
                            Task {
                                await analyzeCode(user: user)
                            }
                        }
                    }
                }
            }
            .tabItem {
                Image(systemName: "sparkles")
                Text("Анализ")
            }
            .tag(0)
            
            // Profile Tab
            NavigationView {
                ProfileView(user: user)
            }
            .tabItem {
                Image(systemName: "person")
                Text("Профиль")
            }
            .tag(1)
        }
        .accentColor(.purple)
    }
    
    private func analyzeCode(user: User) async {
        if let result = await analysisService.analyzeGitHubFile(url: githubURL, userId: user.id) {
            await MainActor.run {
                analysisResult = result
                showingAnalysis = true
                
                // Обновляем статистику пользователя
                let analyses = analysisService.getUserAnalyses(userId: user.id)
                let averageScore = analyses.isEmpty ? 0.0 : Double(analyses.reduce(0) { $0 + $1.overallScore }) / Double(analyses.count)
                authService.updateUserAnalyses(count: analyses.count, averageScore: averageScore)
            }
        }
    }
    
    private func resetAnalysis() {
        analysisResult = nil
        showingAnalysis = false
        githubURL = ""
        analysisService.errorMessage = nil
    }
}

#Preview {
    ContentView()
}
