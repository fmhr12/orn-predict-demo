library(shiny)
library(shinythemes)
library(survival)
library(riskRegression)
library(fastshap)
library(shapviz)
library(ggplot2)
library(prodlim)
library(gower)       
library(plotly)

# -----------------------
# Function to compute Gower distance from a single row to each row of a DF
# -----------------------
compute_gower_distances <- function(single_row, df_full) {
  distances <- gower::gower_dist(single_row, df_full)
  return(as.numeric(distances))
}

# -----------------------
# 1. Load Final Model
# -----------------------
saved_model_path <- "final_fg_model_update.rds"
final_model <- readRDS(saved_model_path)

# -----------------------
# 2. Load the PRECOMPUTED final_grid_data (SHAP values)
# -----------------------
precomputed_path <- "precomputed_shap_grid_multi_times2.rds"
final_80grid_data <- readRDS(precomputed_path)

# -----------------------
# 3. Load the PRECOMPUTED average CIF data (for reference curves)
# -----------------------
# Overall, ORN Positive, and ORN Negative curves
mean_cif_data_overall <- readRDS("mean_cif_data_all.rds")
mean_cif_data_pos     <- readRDS("mean_cif_data_ORN_positive.rds")
mean_cif_data_neg     <- readRDS("mean_cif_data_ORN_negative.rds")

# For SHAP baseline calculation we continue to use the overall data.
mean_cif_data <- mean_cif_data_overall

feature_cols <- c( "Insurance_Type", "Periodontal_Grading_Merged",
                  "Disease_Site_Merged_2", 
                  "Smoking_Pack_per_Year", 
                  "D10cc")

# (Optional) label mapping
label_mapping <- list(
  "Insurance_Type" = c("0" = "Out-of-Pocket", "1" = "Private", "2" = "Public"),
  "Periodontal_Grading_Merged" = c("0" = "0", "1" = "I-II", "2" = "III-IV"),
  "Disease_Site_Merged_2" = c("0" = "Others", "1" = "Oropharynx", "2" = "Oral Cavity")
)

map_labels <- function(df, label_mapping) {
  df_mapped <- df
  for (feature in names(label_mapping)) {
    if (feature %in% colnames(df)) {
      levs <- names(label_mapping[[feature]])
      labs <- unname(label_mapping[[feature]])
      df_mapped[[feature]] <- factor(df_mapped[[feature]], levels = levs, labels = labs)
    }
  }
  df_mapped
}

# -----------------------
# UI
# -----------------------
ui <- fluidPage(
  theme = shinytheme("flatly"),
  
  titlePanel("ORN Prognosis Tool"),

  sidebarLayout(
    sidebarPanel(
      h4("Enter Predictor Values"),
      
      # Predictor inputs
      selectInput("Disease_Site_Merged_2", "Tumor Site",
                  choices = list("Others" = "0", "Oropharynx" = "1", "Oral Cavity" = "2"),
                  selected = "2"),
      numericInput("D10cc", "D10cc (Gy)", value = 63.2, min = 0, max = 100),
      selectInput("Periodontal_Grading_Merged", "Periodontal Grading",
                  choices = list("0" = "0", "I-II" = "1", "III-IV" = "2"),
                  selected = "1"),
      selectInput("Insurance_Type", "Dental Insurance Status",
                  choices = list("Out-of-Pocket" = "0", "Private" = "1", "Public" = "2"),
                  selected = "1"),
      numericInput("Smoking_Pack_per_Year", "Smoking Pack-Year", value = 10, min = 0, max = 200),

      # New inputs for time points:
      # For SHAP explanation (a single time point)
      selectInput("shap_time_point", "Time Point for SHAP", 
                  choices = c("36", "60","84", "114"), selected = "60"),
      
      # For CIF predictions (multiple comma-separated values)
      textInput("cif_time_points", "Time Points for CIF Predictions (comma-separated)", 
                value = "60, 114"),
      
      # Checkbox group for reference curves
      checkboxGroupInput("showReference", "Show Reference (Average CIF) in PMCC", 
                         choices = list("Average Overall" = "overall", 
                                        "Average ORN Positive" = "pos", 
                                        "Average ORN Negative" = "neg"),
                         selected = ""),
      
      actionButton("predictBtn", "Predict & Explain"),
      br(),
      helpText("")
    ),
    
    mainPanel(
      tabsetPanel(
        tabPanel("Results",
          h4("CIF Curve"),
          plotlyOutput("plotCIF"),
          br(),
          h4("CIF Values at Requested Time Points"),
          tableOutput("cifValues"),
          br(),
          h4("SHAP Force Plot (Approx.)"),
          plotOutput("forcePlot", height = "300px")
        )
      )
    )
  )
)

# -----------------------
# SERVER
# -----------------------
server <- function(input, output, session) {

  # Create a 1-row data frame from user inputs
  newdata_reactive <- reactive({
    data.frame(
      Disease_Site_Merged_2 = factor(input$Disease_Site_Merged_2, levels = c("0", "1", "2")),
      D10cc = as.numeric(input$D10cc),
      Periodontal_Grading_Merged = factor(input$Periodontal_Grading_Merged, levels = c("0", "1", "2")),
      Insurance_Type = factor(input$Insurance_Type, levels = c("0", "1", "2")),
      Smoking_Pack_per_Year = as.numeric(input$Smoking_Pack_per_Year)
    )
  })
  
  observeEvent(input$predictBtn, {
    one_indiv <- newdata_reactive()
    
    # -----------------------
    # 1. Predict & Plot CIF curve for the individual
    # -----------------------
    time_grid <- seq(0, 114, by = 1)
    indiv_cif <- predictRisk(final_model, newdata = one_indiv, times = time_grid, cause = 1)
    cif_values <- as.numeric(indiv_cif[1, ])
    
    output$plotCIF <- renderPlotly({
      df_plot <- data.frame(
        Time = time_grid,
        CIF  = round(cif_values, 3)
      )
      
      p <- ggplot(df_plot, aes(x = Time, y = CIF)) +
        geom_line(color = "blue") +
        geom_point(aes(text = paste0("Time: ", Time, "\nCIF: ", sprintf('%.3f', CIF))),
                   color = "blue", size = 1) +
        theme_minimal() +
        labs(x = "Time (months)", y = "CIF")
      
      # Add reference curves based on selected options
      if("overall" %in% input$showReference) {
        p <- p +
          geom_line(data = mean_cif_data_overall, aes(x = Time, y = MeanCIF),
                    color = "red", linetype = "dashed") +
          geom_point(data = mean_cif_data_overall, aes(x = Time, y = MeanCIF,
                                                       text = paste0("Time: ", Time, "\nOverall CIF: ", sprintf('%.3f', MeanCIF))),
                     color = "red", size = 1)
      }
      if("pos" %in% input$showReference) {
        p <- p +
          geom_line(data = mean_cif_data_pos, aes(x = Time, y = MeanCIF),
                    color = "orange", linetype = "dotted") +
          geom_point(data = mean_cif_data_pos, aes(x = Time, y = MeanCIF,
                                                   text = paste0("Time: ", Time, "\nORN Positive CIF: ", sprintf('%.3f', MeanCIF))),
                     color = "orange", size = 1)
      }
      if("neg" %in% input$showReference) {
        p <- p +
          geom_line(data = mean_cif_data_neg, aes(x = Time, y = MeanCIF),
                    color = "green", linetype = "dotdash") +
          geom_point(data = mean_cif_data_neg, aes(x = Time, y = MeanCIF,
                                                   text = paste0("Time: ", Time, "\nORN Negative CIF: ", sprintf('%.3f', MeanCIF))),
                     color = "green", size = 1)
      }
      
      ggplotly(p, tooltip = "text")
    })
    
    # -----------------------
    # 2. Show CIF values at user-requested times in a table
    # -----------------------
    user_times_vec <- as.numeric(trimws(strsplit(input$cif_time_points, ",")[[1]]))
    user_times_vec <- user_times_vec[!is.na(user_times_vec)]
    if(length(user_times_vec) == 0) user_times_vec <- c(60)
    
    indiv_cif_interest <- predictRisk(final_model, newdata = one_indiv, 
                                      times = user_times_vec, cause = 1)
    
    output$cifValues <- renderTable({
      data.frame(
        Time = user_times_vec,
        CIF = sprintf("%.3f", as.numeric(indiv_cif_interest))
      )
    }, digits = 0, align = 'c')
    
    # -----------------------
    # 3. SHAP Explanation with Additive Offset
    # -----------------------
    # Use the selected SHAP time point (from the new selectInput)
    shap_time_point <- as.numeric(input$shap_time_point)
    
    # Compute Gower distances to find similar cases
    k_val <- 3
    dist_vector <- compute_gower_distances(one_indiv, final_80grid_data[feature_cols])
    neighbor_idx <- order(dist_vector)[1:k_val]
    neighbor_dist <- dist_vector[neighbor_idx]
    inv_dist <- 1 / (neighbor_dist + 1e-8)
    wts <- inv_dist / sum(inv_dist)
    
    # Retrieve SHAP columns for the chosen time point (e.g., "_t60")
    shap_suffix <- paste0("_t", shap_time_point)
    shap_cols <- grep(shap_suffix, names(final_80grid_data), value = TRUE)
    
    shap_neighbors <- final_80grid_data[neighbor_idx, shap_cols, drop = FALSE]
    shap_neighbors_mat <- as.matrix(shap_neighbors)
    shap_estimate_mat  <- t(shap_neighbors_mat) %*% wts
    shap_estimate      <- as.numeric(shap_estimate_mat)
    
    shap_feature_names <- sub(shap_suffix, "", shap_cols)
    shap_named <- setNames(shap_estimate, shap_feature_names)
    
    # Baseline from the overall CIF curve (used for SHAP explanation)
    baseline_orig <- approx(x = mean_cif_data$Time, 
                            y = mean_cif_data$MeanCIF, 
                            xout = shap_time_point, rule = 2)$y
    
    # Model prediction at the chosen time point
    model_prediction <- as.numeric(predictRisk(final_model, newdata = one_indiv, 
                                               times = shap_time_point, cause = 1))
    
    # Compute the offset so that: baseline_orig + sum(shap_named) + offset = model_prediction
    offset <- model_prediction - (baseline_orig + sum(shap_named))
    
    # Redistribute the offset among the predictors proportionally to the magnitude of their SHAP values
    if (sum(abs(shap_named)) > 0) {
      shap_adjusted <- shap_named + offset * (abs(shap_named) / sum(abs(shap_named)))
    } else {
      shap_adjusted <- shap_named
    }
    
    # Build the shapviz object using the adjusted SHAP values (without an extra 'Unattributed' bar)
    one_indiv_labeled <- map_labels(one_indiv, label_mapping)
    # No need to add an extra column for unattributed here
    shap_df <- as.data.frame(t(shap_adjusted))
    
    sv_obj <- shapviz(
      object   = as.matrix(shap_df), 
      X        = one_indiv_labeled, 
      baseline = baseline_orig
    )
    
    # Render the SHAP force plot
    output$forcePlot <- renderPlot({
      sv_force(sv_obj, row_id = 1, max_display = ncol(shap_df)) +
        labs(title = paste("SHAP Force Plot at Time =", shap_time_point)) +
        theme(aspect.ratio = 0.25, 
              plot.title = element_text(hjust = 0.5))
    })
  })
}

shinyApp(ui = ui, server = server)
